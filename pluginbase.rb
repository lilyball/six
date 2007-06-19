
#
# CyBot plugin root class.
#

class PluginBase

  # Command flags.
  CmdFlag_Normal    = 0   # Normal command.
  CmdFlag_Channel   = 1   # Channel-bound command.
  CmdFlag_Server    = 2   # Server-bound command.
  CmdFlag_Multiple  = 4   # Command exists in multiple plugins (exclusive flag).

  # Override this to do weird stuff :-p.
  def PluginBase.shared_instance
    @instance ||= self.new
  end

  # Force a new instance to be created. Used when loading.
  def PluginBase.instance
    @instance = self.new
  end

  # Reload support. Called on the _instance_.
  # Before: Called just before reload would take place. Returning a string will disallow
  #         the reload with that as a reason.
  # After:  Called right after the reload. Returning true will create a new instance for
  #         the plugin. Remeber to save in that case, since the new instance will invoke
  #         load, as usual.

  def before_reload(forced = false)
    nil
  end
  def after_reload(forced = false)
    false
  end

  # Called when a reload fails due to compile errors. Return a string to use as error,
  # or nil for the default.
  def reload_failed(exception)
  end

  # Access to stuff.
  attr_reader :commands, :hooks, :brief_help
  attr_accessor :sensitive_command

  # Register a command.
  def register_command(name, method_name, flags, help_map)
    cmd = [flags, method(method_name.to_sym), self, help_map && help_map[name.to_sym]]
    @commands[name] = cmd
    if (c = $commands[name])
      if c[0] != CmdFlag_Multiple
        $commands[name] = (c = [CmdFlag_Multiple, c])
      end
      c << cmd
    elsif (p = $plugins[name])
      $commands[name] = [CmdFlag_Multiple, cmd]
    else
      $commands[name] = cmd
    end
  end

  # Register commands for the given plugin instance.
  def register_commands

    # Step 1: Register new commands.
    help_map = self.class.help_map
    self.class.instance_methods(false).each do |name|

      if name =~ /^cmd_(.*)$/
        register_command($1, name, CmdFlag_Normal, help_map)
      elsif name =~ /^serv_(.*)$/
        register_command($1, name, CmdFlag_Server, help_map)
      elsif name =~ /^chan_(.*)$/
        register_command($1, name, CmdFlag_Channel, help_map)
      elsif name =~ /^hook_(.*)$/
        hook = $1.to_sym
        h = [method(name.to_sym), hook, self]
        hook_list = $hooks[hook] || ($hooks[hook] = [])
        @hooks << h
        hook_list << h
      end
    end

    # Step 2: Fix-up old commands to avoid ambiguity.
    if @commands.length > 0 and (c = $commands[name]) and c[0] != CmdFlag_Multiple
      $commands[name] = [CmdFlag_Multiple, c]
    end

    # Step 3: Clean up.
    self.class.help_map = nil

  end

  # We need to be able to call this.
  class << self
    public :remove_method
  end

  # Unregister commands and hooks for this plugin. Override to do dispose stuff.
  def unregister

    # Commands...
    klass = self.class
    @commands.each do |k,v|

      # Remove method.
      name = case v[0]
        when CmdFlag_Normal:  'cmd_'
        when CmdFlag_Channel: 'chan_'
        when CmdFlag_Server:  'serv_'
      end + k.to_s
      klass.remove_method name.to_sym

      # Remove from global maps.
      if (cmd = $commands[k])
        if cmd[0] != CmdFlag_Multiple
          $commands.delete(k) if cmd[2].class == klass
        else
          j = cmd.each_with_index do |c, i|
            next unless i > 0
            break i if c[2].class == klass
          end
          cmd.delete_at(j) if j != cmd
        end
      end

    end

    # Hooks...
    @hooks.each do |h|
      klass.remove_method "hook_#{h[1]}".to_sym
      if (hook = $hooks[h[1]])
        hook.delete_if { |e| e[2].class == klass }
      end
    end

    # Clean up.
    @commands = {}
    @hooks = []

  end

  # Only override this if you know what you're doing.
  def name
    @name ||= self.class.name.downcase
  end

  # Remember to call this to get your commands regged.
  def initialize
    @commands = {}
    @hooks = []
    @brief_help = "#{name.capitalize} plugin." unless @brief_help
    register_commands
    load
  end

  # Return the relative filename for this plugin.
  def file_name(name = nil)
    dir = "data/#{self.class.name.downcase}"
    dir << '/' if name and name[0] != ?/
    "#{dir}#{name}"
  end

  # Open or create a plugin data-file. Can accept a block.
  def open_file(name, mode = 'r', &block)
		# Check that data exists
		Dir.mkdir('data') unless File.directory?('data')
		
    path = "data/#{self.class.name.downcase}"
    Dir.mkdir(path) unless File.directory?(path)
    File.open("#{path}/#{name}", mode, &block)
  end

  # Load/save plugin-state. Override to do anything here.
  # These are called on init and before the bot quits.
  def load
  end
  def save
  end

  # Command help generator.
  class << self
    def help(cmd, help)
      hm = @help_map || (@help_map = {})
      hm[cmd] = help
    end
    attr_accessor :help_map
  end

  # Command parser wrapper generator.
  # Argument types:
  #   nick          A nick name.
  #   channel       A channel the bot is on, or automatically
  #                 set to the channel the command is called from.
  #   anychannel    Arbitrary channel name.
  #   integer       An integer.
  #   text          Any text, possibly empty. Must be last argument.
  #   text_ne       Any (non-empty) text. Ditto.
  #
  def PluginBase.parse(name, *args)

    # No args, nothing to do.
    return unless args.length > 0

    # Alias old method.
    new_name = '__parse_' + name.to_s
    alias_method(new_name.to_sym, name.to_sym)

    # And put in our new one.
    code = <<-EOS
      def #{name.to_s}(irc, line)
        #{new_name}(irc, *parse(irc, line, #{args.map {|a| a.kind_of?(String) ?
          ('"' + a + '"') : (':' + a.to_s)}.join(', ')}))
      end
    EOS
#    $log.puts "Genrated code: " + code
    class_eval code

  end

  # Argument parse error.
  class ParseError < Exception
    def initialize(msg, arg_num, usage, format)
      super("Argument #{arg_num + 1}: #{msg}")
      @usage  = usage
      @format = format
    end
    def usage
      @usage ? @usage : (@format.map { |f|
         case f
         when :nick:         '<nick name>'
         when :channel:      '[bot channel]'
         when :anychannel:   '<channel>'
         when :integer:      '<integer>'
         when :text:         '[string]'
         when :text_ne:      '<string>'
         end
      }.join(' '))
    end
  end

  # Argument parser.
  def parse(irc, line, *forms)
    usage = forms[0].kind_of?(String) ? forms.delete_at(0) : nil
    args = []
    line ||= ''
    forms.length.times do |i|
      f = forms[i]

      # Text. Last argument.
      if f == :text or f == :text_ne
        line = line.strip if line
        if f == :text_ne and (!line or line.length == 0)
          raise ParseError.new('Non-empty string expected.', i, usage, forms)
        end
        args << (line ? line : '')
        break

      # Current- or bot-channel.
      elsif f == :channel
        if (c = irc.channel)
          args << c
        else
          if line: word, line = line.split(' ', 2)
          else word = nil end
          unless word and (c = irc.server.channels[word])
            raise ParseError.new('Bot-channel name expected.', i, usage, forms)
          end
          args << c
        end

      # Other tokens.
      else
        if line: word, line = line.split(' ', 2)
        else word = nil end
        unless word and word.length > 0
          raise ParseError.new('Not enough arguments.', i, usage, forms)
        end
        case f

        # Nick name.  FIXME?
        when :nick
          args << word

        # Channel name.
        when :anychannel
          unless word and word.length > 0 and (word[0] == ?# or word[0] == ?&)
            raise ParseError.new('Channel name expected.', i, usage, forms)
          end
          args << word

        # Integer.
        when :integer
          begin
            int = Integer(word)
            args << int
          rescue ArgumentError
            raise ParseError.new('Integer expected.', i, usage, forms)
          end

        end
      end

    end
    args
  end

  # Date formatter.
  WeekDays = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday']
  def human_date(ts)
    days, now = ts.to_i / (24*60*60), Time.now.to_i / (24*60*60)
    if days == now:         "at #{ts.strftime('%H:%M')}"
    elsif days + 1 == now:  "yesterday at #{ts.strftime('%H:%M')}"
    elsif days + 6 <= now:  "#{WeekDays[ts.wday]} at #{ts.strftime('%H:%M')}"
    else                    "on #{ts.strftime('%m-%d %H:%M')}"
    end
  end

  # Evaluate a setting (or settings) on channel and server levels, with optional
  # global level provided by the passed block.
  def setting_cs(irc, name = nil)
    a = nil
    if (s = $config["servers/#{irc.server.name}"])
      if (c = s['channels']) and (c = c[irc.channel.name])
        a = name ? c[name] : yield(c)
      end
      if a.nil?
        a = name ? s[name] : yield(s)
      end
    end
    if a.nil? and block_given?
      a = name ? yield : yield(nil)
    end
    a
  end


  # ---------------------------------------------------------------------------
  # Time duration formatter.
  # ---------------------------------------------------------------------------

  X_TimeWords = %w{ one two three four five six seven eight nine ten eleven twelve } # thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty

  X_TimeUnits = [
    [ "year",    365   * 60 * 60 * 24 ],
    [ "month",    30.4 * 60 * 60 * 24 ],
    [ "week",      7   * 60 * 60 * 24 ],
    [ "day",      24   * 60 * 60      ],
    [ "hour",     60   * 60           ],
    [ "minute",   60                  ],
    [ "second",    1                  ],
  ]

  X_TimePrefixes = { :greater => "almost ", :less => "about " }

  def _round_time(seconds, unit_size)
    count = seconds.to_f / unit_size
    case count % 1.0
      when 0.0:      [ count.to_i,  :exact   ]
      when 0.0..0.3: [ count.floor, :less    ]
      when 0.3..0.7: [ count.to_i,  :trunc   ]
      when 0.7..1.0: [ count.ceil,  :greater ]
    end
  end

  def _format_time(count, unit_name)
    number = count < X_TimeWords.length ? X_TimeWords[count-1] : count.to_s
    unit = unit_name + (count > 1 ? "s" : "")
    return number + " " + unit
  end

  def seconds_to_s_fuzzy(seconds)
    return "zero seconds" if seconds == 0
    X_TimeUnits.each_index do |i|
      unit_name, unit_size = X_TimeUnits[i]

      number_of = seconds.to_f / unit_size
      next if number_of <= 0.7

      cnt, action = _round_time(seconds, unit_size)
      if action == :trunc
        sub_unit_name, size = X_TimeUnits[i+1]
        sub_cnt = ((seconds % unit_size).to_f / size).round
        return "#{_format_time cnt, unit_name} and #{_format_time sub_cnt, sub_unit_name}"
      else
        return "#{X_TimePrefixes[action]}#{_format_time cnt, unit_name}"
      end
    end
  end

  def seconds_to_s_exact(seconds)
    s = seconds % 60
    m = (seconds /= 60) % 60
    h = (seconds /= 60) % 24
    d = (seconds /= 24)
    out = []
    out << "#{d}d" if d > 0
    out << "#{h}h" if h > 0
    out << "#{m}m" if m > 0
    out << "#{s}s" if s > 0
    out.length > 0 ? out.join(' ') : '0s'
  end

  def seconds_to_s(seconds, irc = nil)
    if irc and (u = $user.get_data(irc.from.nick, irc.server.name)) and !(u['fuzzy-time'] == false)
      seconds_to_s_fuzzy(seconds)
    else
      seconds_to_s_exact(seconds)
    end
  end


end

