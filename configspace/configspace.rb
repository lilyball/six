#
# ConfigSpace - A tree-structured configuration system.
#

# We need this for marshalling.
require 'yaml'

module YAML
  class << self
    unless method_defined? :load_file
      def load_file(file)
        YAML.load(File.read(file))
      end
    end
  end
end

# Module for booleans. User types must support a 'from_str' similar to this.
# Note we interpret 'nil' as true, since this is often used for boolean flags,
# in which case the user typing 'set flag' means to turn it on.
module Boolean
  def Boolean.from_str(thing)
    if thing.nil?
      true
    elsif !thing or thing.kind_of?(TrueClass)
      !!thing
    elsif thing.kind_of?(Integer)
      thing != 0
    elsif thing.kind_of?(String)
      case thing.downcase
      when 'no', 'off', '0', 'false', '-', 'disabled': false
      else true
      end
    end
  end
end

# Path class, to make things nicer and easier.
class Path < Array

  # Initialize from string, array or Path.
  def initialize(path)
    super()
    case path
    when Array, Path: replace(path)
    when String: replace(path.split('/').reject { |e| e.length == 0 })
    end
  end

  # Concat.
  def <<(path)
    if path.kind_of?(String)
      concat(path.split('/').reject { |e| e.length == 0 })
    else super
    end
  end

  # Ditto.
  def +(path)
    if path.kind_of?(String)
      dup.concat(path.split('/').reject { |e| e.length == 0 })
    else dup << path
    end
  end

  # String representation.
  def to_s
    '/' + join('/')
  end

  # First, last and slice.
  alias_method :old_first, :first
  alias_method :old_first, :first
  alias_method :old_index, :[]
  def first(num)
    Path.new(old_first(num))
  end
  def last(num)
    Path.new(old_last(num))
  end
  def [](index)
    index.kind_of?(Range) ? Path.new(old_index(index)) : super
  end

end

# The main class to manage a config space.
class ConfigSpace

  # OnChange types and actions:

  # Surounding directory added or removed.
  # [dir].
  HookRootAdd       = 1
  HookRootDelete    = 2

  # Item creation and removal.
  # [new_item] => new_item.
  HookCreate        = 10

  # Element added to array.
  # [array, new_element] => new_element.
  HookArrayAdd      = 3

  # Element removed from array.
  # [array, value].
  HookArrayDelete   = 4

  # Element set or changed.
  # [map, key, value, new_value] => new_value.
  HookSet           = 5

  # Element (file or firectory) was deleted.
  # [map, key].
  HookDelete        = 6


  # Errors.
  class Error < Exception
    Ok            = 0
    FileError     = 1
    Collision     = 2
    NoPath        = 3
    WrongType     = 4
    IllegalName   = 5
    DirExpected   = 6
    NoArrItem     = 7
    UnsafeDel     = 8
    NoDelete      = 9
    def initialize(code, path = nil, item = nil)
      if code.kind_of?(String)
        super(code)
        @code = nil
      else
        @code = code
        super(case code
          when FileError:   'Error accessing file' + (path ? " #{path}" : '')
          when Collision:   'Config space collision' + (path ? " at path '#{path}'" : '')
          when NoPath:      'Path not found' + (path ? ": #{path}" : '')
          when WrongType:   'Incompatible keys' + (path ? " at path '#{path}'" : '')
          when IllegalName: "Illegal directory name '#{path}'"
          when DirExpected: 'Directory expected' + (path ? " at path '#{path}'" : '')
          when NoArrItem:   'No such array item' + (item ? " '#{item}'" : '') +
            (path ? " at path '#{path}'" : '')
          when UnsafeDel:   'The entry' + (path ? " [#{path}]" : '') +
            ' is an array or a directory. Specify the path and item separately if you want to delete it.'
          when NoDelete:    "Can only delete from arrays and directories. The object #{path} is neither."
        end)
      end
    end
    attr_reader :code
  end

  attr_accessor :allow_dir_set, :allow_dir_add
  attr_accessor :prefix, :suffix
  attr_reader :file

  # Initializes a config space, optionally reading a marshalled file.
  def initialize(config_file = nil, meta_tree = nil)
    @meta = meta_tree || { :dir => true }
    begin
      if config_file: load(config_file)
      else @cfg = {} end
    rescue StandardError => e
      $log.puts "Exception loading ConfigSpace: #{e.inspect}"
      raise e
    end
  end

  # Loads the config space from a file.
  def load(file = nil)
    @file = file if file
    @cfg = YAML.load_file(@file)
  end

  # Dumps the config space to a file. Returns success.
  def save(file = nil)
    @file = file if file
    raise Error.new(Error::FileError) unless @file
    File.open(@file, 'w') do |f|
      f.puts(@prefix) if @prefix
      YAML.dump(@cfg, f)
      f.puts ''
      f.puts(@suffix) if @suffix
    end
  end

  # Merge in a config space at the path specified.
  def merge(space, path = nil)

    # Follow the path.
    path = Path.new(path) unless path.kind_of?(Path)
    m = meta_walk(path)

    # First, verify that we can add. Then add.
    merge_in(m, space, path, true)
    merge_in(m, space, path)

  end

  # Return the help sting associated with the given path.
  def help(path = nil)
    path = Path.new(path) unless path.kind_of?(Path)
    m = meta_walk(path)
    m.kind_of?(Hash) ? m[:help] : m
  end

  def dump
    $log.puts 'Meta:'
    p @meta
    $log.puts 'Config:'
    p @cfg
  end

  def dump_cfg
    $log.puts 'Config:'
    p @cfg
  end

  # Get config item directly, optionally returning a given default value.
  def [](path, default = nil)
    _, cmap = dir_walk(path.kind_of?(Path) ? path : Path.new(path), DW_Nil) || [0, default]
    cmap
  end

  # Get config item, creating dirs as needed _including_ the final path element.
  def ensure(path)
    _, cmap = dir_walk(path.kind_of?(Path) ? path : Path.new(path), DW_Create)
    cmap
  end

  # Set config item directly. It's YOUR OWN responsibility to maintain sanity.
  # Returns the value set.
  def []=(path, value)
    path = Path.new(path) unless path.kind_of?(Path)
    key = path.pop
    mmap, cmap = dir_walk(path, DW_Create)
    oldval = cmap[key]
    hook = mmap[:on_change] and value = hook.call(HookSet, cmap, key, oldval, value) || value
    if oldval.respond_to?(:replace)
      oldval.replace(value)
      oldval
    else
      cmap[key] = value
      value
    end
  end


  # Stat/walk modes.
  StatNormal    = 0   # Missing config is ok, as long as meta is there.
  StatStrict    = 1   # Missing config is skipped.

  # Walk return codes from block.
  WalkNext      = 0   # Next entry. Default.
  WalkDescend   = 1   # Descend into directory.
  WalkReturn    = 2   # Exit out of directory.
  WalkAbort     = 3   # Exit entire walk.

  # Get stats on a path. Mode decides how missing config is handled.
  def stat(path = nil, mode = StatNormal)

    # Find entry, and return. Dead simple :-p.
    path = Path.new(path) unless path.kind_of?(Path)
    mmap, cmap = dir_walk(path, mode == StatStrict ? DW_Fail : DW_Nil)
    [mmap, cmap, path]

  end

  # Walk a path. Can deal with skeletons. Can accept result from stat as 'path'.
  # Fails on non-dirs. Yields [meta, config] pairs.
  def walk(path = nil, mode = StatNormal)

    # Go to initial position, if needed.
    if path.kind_of?(String) or path.kind_of?(Path)
      m, c = stat(path, mode)
    else
      m, c = path
    end

    # If not a directory, fail.
    unless m.kind_of?(Hash) and m[:dir]
      raise Error.new(Error::DirExpected, path)
    end

    # Walk this level.
    c ||= {}
    m.each do |k,v|
      cv = c[k]
      next if k.kind_of?(Symbol) or (mode == StatStrict and !cv)
      case yield(k, v, cv)
      when WalkDescend
        if v.kind_of?(Hash) and v[:dir]
          return WalkAbort if walk([v, cv], mode) == WalkAbort
        end
      when WalkAbort
        return WalkAbort
      when WalkReturn
        return WalkReturn
      end
    end

    # Skeleton walk if needed.
    if (sk = m[:skel])
      c.each do |k,cv|
        next if m[k]
        case yield(k, sk, cv)
        when WalkDescend
          if sk[:dir]
            return WalkAbort if walk([sk, cv], mode) == WalkAbort
          end
        when WalkAbort
          return WalkAbort
        when WalkReturn
          return WalkReturn
        end
      end
    end
    true

  end


  # Types, returned by get, set, add and del.
  TypeItem      = 1   # An item. [path, file_name, new_value].
  TypeDirectory = 2   # Added directory. [path, dir_name].
  TypeDirExists = 3   # Skipped existing directory. [path, dir_name].
  TypeArray     = 4   # Array item. [array, item, new_value].

  # Get config item.
  def get(path)
    _, cmap = dir_walk(path.kind_of?(Path) ? path : Path.new(path), DW_Fail)
    cmap
  end

  # Set config item at path to value. Creates necessary intermediate directories.
  def set(path, value)

    # Verify.
    path = Path.new(path) unless path.kind_of?(Path)
    meta = meta_walk(path)
    if meta and meta.kind_of?(Hash)
      raise Error.new(Error::WrongType, path) if meta[:dir]
      if (t = meta[:type])
        value = convert_to(value, t, path) unless value.kind_of?(t)
      end
    else
      value = value.to_s
    end

    # Perform the set.
    key = path.pop
    mmap, cmap = dir_walk(path, DW_Create)
    oldval = cmap[key]
    if (hook = mmap[:on_change])
      value = hook.call(HookSet, cmap, key, oldval, value) || value
    end
    if oldval.respond_to?(:replace): oldval.replace(value)
    else cmap[key] = value end
    [TypeItem, path, key, value]

  end

  # Add items to array, or create directories.
  def add(path, value)

    # Verify.
    path = Path.new(path) unless path.kind_of?(Path)
    meta = meta_walk(path)
    adding_dir = false
    if meta and meta.kind_of?(Hash)
      if meta[:dir]
        value = value.to_s
        raise Error.new(Error::IllegalName, value) if value.include?(?/)
        unless (meta = meta[value]) and meta.kind_of?(Hash) and meta[:dir]
          raise Error.new(Error::WrongType, path)
        end
        adding_dir = true
      else
        raise Error.new(Error::WrongType, path) unless meta[:type] == Array
        if (t = meta[:arraytype])
          value = convert_to(value, t, path) unless value.kind_of?(t)
        else
          value = value.to_s
        end
      end
    else
      raise Error.new(Error::WrongType, path)
    end

    # Creating a directory.
    if adding_dir
      mmap, cmap = dir_walk(path, DW_Create)
      return [TypeDirExists, path, value] if cmap.has_key?(value)
      dir = {}
      if (hook = mmap[:on_change])
        dir = d if (d = hook.call(HookSet, cmap, value, nil, dir))
      end
      cmap[value] = dir
      [TypeDirectory, path, value]

    # Adding an array item.
    else
      key = path.pop
      mmap, cmap = dir_walk(path, DW_Create)
      ihook = meta[:on_change]
      if (a = cmap[key])
        value = ihook.call(HookArrayAdd, a, value) || value if ihook
        a << value
      else
        a = [value]
        a = ihook.call(HookCreate, a) || a if ihook
        dhook = mmap[:on_change]
        a = dhook.call(HookSet, cmap, key, nil, a) || a if dhook
        cmap[key] = a
      end
      [TypeArray, path + key, value, a]

    end
  end

  # Delete settings, delete from arrays or directories.
  def del(path, value)

    # Figure out what to delete FROM. Only directories and arrays supported.
    path = Path.new(path) unless path.kind_of?(Path)
    mmap, cmap = dir_walk(path, DW_Fail)
    unless mmap.kind_of?(Hash) and (mmap[:dir] or mmap[:type] == Array)
      raise Error.new(Error::NoDelete, path)
    end
    hook = mmap[:on_change]

    # Item delete.
    if mmap[:dir]
      value = value.to_s
      raise Error.new(Error::IllegalName, value) if value.include?(?/)
      raise Error.new(Error::NoPath, path + value) unless mmap[value] and (ce = cmap[value])
      hook.call(HookDelete, cmap, value, ce) if hook
      [TypeItem, path, value, cmap.delete(value)]

    # Array delete.
    else
      hook.call(HookArrayDelete, cmap, value) if hook
      raise Error.new(Error::NoArrItem, path, value) unless (v = cmap.delete(value))
      [TypeArray, path, v, cmap]

    end
  end

  # A few helpers to implement set-like semantics on arrays.
  def ConfigSpace.set_semantics(set)
    lambda do |*args| set_sem_verify(set, *args) end
  end

private

  # Internal helpers for set_semantics above.
  def ConfigSpace.set_sem_unknown(set, item)
    raise Error.new("Unknown item '#{item}'. Must be one of: #{set.join(', ')}.")
  end
  def ConfigSpace.set_sem_verify(set, type, *args)
    case type
    when HookCreate
      unknown_flag(set, args[0]) unless set.include? args[0]
    when HookArrayAdd
      unknown_flag(set, args[1]) unless set.include? args[1]
      raise Error.new("This item is already set.") if args[0].include? args[1]
    end
    nil
  end

  # Convert value to type, raising WrongType (with path) if needed.
  def convert_to(value, type, path = nil)
    path = Path.new(path) unless path.kind_of?(Path)
    case type.object_id
    when Integer.object_id
      raise Error.new(Error::WrongType, path) unless value.respond_to?(:to_i)
      value.to_i
    when Float.object_id
      raise Error.new(Error::WrongType, path) unless value.respond_to?(:to_f)
      value.to_f
    when Array.object_id
      # FIXME: Should allow more flexible kinds of lists (with spaces).
      value.to_s.split
    when String.object_id
      value.to_s
    else
      raise Error.new(Error::WrongType, path) unless type.respond_to?(:from_str)
      type.from_str(value)
    end
  end

  # Modes for dir_walk.
  DW_Nil    = 0   # Ignore missing entries, and return nil.
  DW_Create = 1   # Create missing entries as directories.
  DW_Fail   = 2   # Raise exception on missing entry.

  # Walks config space in different modes.
  def dir_walk(path, mode)
    return [@meta, @cfg] unless path and (path.length > 0)
    mmap = @meta
    cmap = @cfg
    path.length.times do |i|
      str = path[i]
      me = mmap[str] || mmap[:skel]
      unless ce = cmap[str]
        return nil if mode == DW_Nil
        raise Error.new(Error::NoPath, path[0..i]) if mode == DW_Fail
        if (hook = mmap[:on_change])
          ce = hook.call(HookSet, cmap, str, nil, {})
        end
        cmap[str] = (ce ||= {})
      end
      mmap = me
      cmap = ce
    end
    [mmap, cmap]
  end

  # Walks the meta map prior to config space access, performing all necessary checks.
  def meta_walk(path = nil, map = @meta)
    return map unless path and (path.length > 0)
    path.length.times do |i|
      str = path[i]
      unless map.kind_of?(Hash) and map[:dir]
        raise Error.new(Error::NoPath, path[0..i])
      end
      if !(m = map[str]) and !(m = map[:skel])
        raise Error.new(Error::NoPath, path[0..i])
      end
      map = m
    end
    map
  end

  def merge_in(map, space, path, verify = false)
    space.each do |k,v|

      # Case 1: No existing entry. Then just merge the new tree.
      next if k == :dir
      kn = k.kind_of?(Symbol) ? '*' : k.to_s
      if !(val = map[k])
        map[k] = v unless verify

      # Case 2: Existing dir entry. Recurse if new entry is also a dir.
      elsif val.kind_of?(Hash) and v.kind_of?(Hash) and val[:dir] and v[:dir]
        merge_in(val, v, path ? (path + kn) : Path.new(kn), verify) or
          raise Error.new(Error::WrongType, path + kn)

      # Case 3: Incompatibility.
      else
        raise Error.new(Error::Collision, path + kn)
      end

    end
  end

end


if $0 == __FILE__
begin

  $config = ConfigSpace.new


  # Set-up config space.
  $config.merge(
    :help => 'CyBot configuration directory.',
    'comm' => {
      :dir => true,
      :help => 'Bot communication settings.',
      'use-notices' => {
        :help => 'Use notices instead of messages for channel replies.',
        :type => Boolean
      }
    },
    'irc' => {
      :dir => true,
      :help => 'Global IRC settings.',
      'channels' => {
        :help => 'Channels to keep the bot on.',
        :type => Array
      },
      'nicks' => {
        :help => 'Nick names to use.',
        :type => Array
      }
    },
    'servers' => {
      :help  => 'List of IRC servers to connect to.',
      :dir => true,
      :skel => {
        :dir => true,
        :help => 'Settings for the IRC server.',
        'host' => 'Host of the IRC server.',
        'port' => 'TCP port of the IRC server.',
        'nicks' => {
          :help => 'Nick names to use. Replaces global list (irc/nicks).',
          :type => Array
        },
        'channels' => {
          :help => 'Channels this bot should be on, in addition to the global list (irc/channels).',
          :type => Array
        }
      }
    }
  )

  # Our change-hook.
  def on_change(type, map, key, *args)
    $log.puts "> Type: #{type}  key: #{key}  args: #{args.inspect}"
    nil
  end


  # Config space addition.
  $config.merge(
    'servers' => {
      :dir => true,
      :on_change => lambda {|*args| on_change(*args) },
      :skel => {
        :dir => true,
        'users' => {
          :help => 'User list for this server.',
          :dir => true,
          :skel => {
            :help => 'User settings.',
            :dir => true,
            'masks' => {
              :help => "Host masks for this user.",
              :type => Array
            }
          }
        }
      }
    })
 #   $config.dump

 p $config.set('irc/nicks', [1, 2])
 $config.dump_cfg
 p $config.add('irc/nicks', 3)
 $config.dump_cfg
 gets

 p $config.del('irc/nicks', 2)
 $config.dump_cfg



rescue Exception => e
  $log.puts e.message
  $log.puts e.backtrace.join("\n")
end
end

