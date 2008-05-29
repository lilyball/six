#
# CyBot test plugin.
#

class Test < PluginBase

  def initialize(*args)
    @brief_help = 'A small test plugin.'
    super(*args)
    $config.allow_dir_set = true
    $config.allow_dir_add = true
  end

  # Checks whether the user is allowed to use this plugin
  # Informs them and returns false if not 
  # 
  # This method is copied from plugins/phrases.rb so
  # We may want to move it to our super class (PluginBase)
  def authed?(irc)
    if !$user.caps(irc, 'op', 'owner').any?
      irc.reply "You aren't allowed to use this command"
      return false
    end
    true
  end

  def cmd_echo(irc, line)
    irc.puts line
  end
  help :echo, 'Echoes the given line right back at ya!'

  def chan_say(irc, chan, line)
    return unless authed?(irc)
    chan.privmsg line
  end
  help :say, 'Makes me say the given line in the channel.'

  def chan_do(irc, chan, line)
    return unless authed?(irc)
    chan.action line
  end
  help(:do, 'Makes me emote (using a CTCP action) the given text in the channel.')

  def cmd_commands(irc, line)
    irc.reply "Global commands: #{$commands.keys.sort.join(', ')}."
  end
  help :commands, "Displays a global command list. Deprecated in favor of '?' and '<plugin>?'."

  def cmd_quit(irc, line)
    return unless authed?(irc)
    irc.server.quit_all(line)
  end
  help :quit, 'Gracefully quits CyBot, disconnecting from all servers.'

  def serv_disconnect(irc, serv, line)
    return unless authed?(irc)
    serv.quit(line)
  end
  help :disconnect, 'Makes CyBot disconnect from the current server.'

  def cmd_dump_cfg(irc, line)
    return unless authed?(irc)
    $config.dump
  end
  help :dump_cfg, "Debug command to dump the config tree to the console. Don't use!"

  def cmd_save(irc, line)
    return unless authed?(irc)
    $plugins.each_value { |p| p.save }
    $config.save(line)
    irc.reply "Ok, configuration saved!"
  end
  help :save, 'Saves the current configuration tree.'

  def cmd_load(irc, line)
    return unless authed?(irc)
    $config.load(line)
    irc.reply "Ok, configuration loaded from '#{$config.file}'"
  end
  help :load, 'Loads the configuration tree from disk.'

  def cmd_help(irc, line)
    begin
      irc.reply $config.help(line)
    rescue ConfigSpace::Error => e
      irc.reply e.message
    end
  end
  help :help, 'Gives help on a config tree path.'

  def cmd_set(irc, line)

    return unless authed?(irc)

    # Split arguments.
    if line: path, value = line.split(' ', 2)
    else path = nil end
    unless path and path.length > 0
      irc.reply 'USAGE: set <path> [value]'
      return
    end

    # Go for it.
    begin
      _, p, k, v = $config.set(path, value)
      irc.reply "Ok.  [#{p}/#{k}] #{v.inspect}"
    rescue ConfigSpace::Error => e
      irc.reply e.message
    end

  end
  help :set, 'Sets a config tree item. USAGE: set <path> <value>.'

  def cmd_del(irc, line)

    return unless authed?(irc)

    # Split arguments.
    if line: path, value = line.split(' ', 2)
    else path = nil end
    unless path and path.length > 0
      irc.reply 'USAGE: del <path> [value]'
      return
    end

    # Go for it.
    begin
      t, p, v, n = $config.del(path, value)
      case t
      when ConfigSpace::TypeItem
        irc.reply "Item [#{p}/#{v}] deleted. Was: #{n.inspect}."
      when ConfigSpace::TypeArray
        irc.reply "Item '#{v}' removed from [#{p}]. New value: #{n.inspect}."
      end
    rescue ConfigSpace::Error => e
      irc.reply e.message
    end

  end
  help :del, 'Deletes a config tree item or array item. USAGE: del <path> <item>.'

  def cmd_add(irc, line)

    return unless authed?(irc)

    # Split arguments.
    if line: path, value = line.split(' ', 2)
    else path = nil end
    unless path and path.length > 0 and value and value.length > 0
      irc.reply 'USAGE: add <path> <value>'
      return
    end

    # Go for it.
    begin
      t, p, v, n = $config.add(path, value)
      case t
      when ConfigSpace::TypeDirectory, ConfigSpace::TypeDirExists
        irc.reply "Ok, directory [#{p}/#{v}] created."
      when ConfigSpace::TypeArray
        irc.reply "Ok, added '#{v}' to [#{p}]: #{n.inspect}"
      end
    rescue ConfigSpace::Error => e
      irc.reply e.message
    end

  end
  help :add, 'Adds a config tree item or array item. USAGE: add <path> <item>.'


  def cmd_list(irc, path)
    return unless authed?(irc)
    begin

      # Crude option parsing :p.
      if path and path[0] == ?-
        path = path[1..-1]
        info_mode = true
      else
        info_mode = false
      end

      # The main deal.
      m, c, path = $config.stat(path)
      out = []
      is_dir = m.kind_of?(Hash) && m[:dir]
      if !info_mode and is_dir
        $config.walk([m, c]) do |k,m,c|
          out << (c ? '*' : '') + k + ((m.kind_of?(Hash) && m[:dir]) ? '/' : '')
        end
      else
        if info_mode or is_dir
          out << m[:help]
        else
          out << "#{c.nil? ? '<unset>' : c.inspect}  ---  #{m.kind_of?(Hash) ? m[:help] : m}"
        end
      end
      irc.reply("[#{(c.nil? ? '*' : '')}#{path}] #{out.join(', ')}")

    rescue ConfigSpace::Error => e
      irc.reply e.message
    end
  end
  help :list, 'Lists the config tree leaf corresponding to the given path.'

end

