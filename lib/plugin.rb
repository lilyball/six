#
# Plugin manager plugin.
#

class Plugin < PluginBase

  def initialize
    @brief_help = 'Manages plugins.'
    super
    $config.merge(
      'plugins' => {
        :dir => true,
        'path' => {
          :type => Array
        },
        'autoload' => {
          :type => Array
        }
      }
    )
  end

  # Special initializer method for core plugins. We feel special :-).
  def on_startup
    puts 'Autoloading plugins...'
    autoload = $config['plugins/autoload', []]
    autoload.each do |plugin|
      if $plugins[pn = plugin.downcase]
        puts "Plugin '#{pn.capitalize}' was already loaded; skipping."
      else
        begin
          if !load_plugin(pn)
            irc.reply "Error loading plugin '#{pn.capitalize}': File not found in plugin path."
          elsif (klass = self.class.const_get(pn.capitalize))
            ins = klass.instance
            $plugins[ins.name] = ins
          else
            puts "Error loading plugin '#{pn.capitalize}': Couldn't locate plugin class."
          end
        rescue Exception => e
          puts "Error loading plugin '#{pn.capitalize}':"
          puts e.message
          puts e.backtrace.join("\n")
        end
      end
    end
  end

  # Tries to load a plugin. Returns true if successful, false or exception otherwise.
  def load_plugin(name)
    path = ['lib', 'plugins'] + $config['plugins/path', []]
    path.each do |dir|
      begin
        Plugins.module_eval { load("#{dir}/#{name}.rb") }
        puts "Loaded plugin '#{name.capitalize}' [#{dir}/#{name}.rb]"
        return true
      rescue LoadError
        # Just try the next directory...
      end
    end
    false
  end

  # Reloads a plugin. Note that support is currently SHAKY!
  def cmd_reload(irc, plugin)

    # Caps and usage.
    if !$user.caps(irc, 'admin', 'owner').any?
      irc.reply "You're not a bot administrator, so don't even start!"
      return
    end
    if !plugin or plugin.empty?
      irc.reply "USAGE: reload [-f] <plugin name>, where <plugin name> is as it appears in the list given by 'plugin list'. The -f option can be used to force a reload if the plugin doesn't want to."
      return
    end

    # Check arguments.
    op, pl = plugin.split(' ', 2)
    if op and op == '-f'
      forcing = true
      plugin = pl
    else
      forcing = false
    end

    # Look for plugin.
    if !(p = $plugins[pn = plugin.downcase])
      irc.reply "Plugin '#{plugin}' not found. Try '?' for a list of currently loaded plugins."
      return
    end

    # Before reload business.
    if (r = p.before_reload(forcing)) and r.kind_of?(String)
      if forcing
        irc.reply "WARNING: Forcing reload of plugin, even though it refuses with reason: #{r}"
      else
        irc.reply "Plugin refuses to reload with reason: #{r}"
        return
      end
    end
    p.unregister

    # Reload!
    begin
      unless load_plugin(pn)
        irc.reply "Error reloading plugin: File not found in plugin path."
        return
      end
    rescue Exception => e
      Kernel.puts "Error loading plugin '#{pn.capitalize}':"
      Kernel.puts e.message
      Kernel.puts e.backtrace.join("\n")
      msg = p.reload_failed(e) || e.message
      irc.reply "Error reloading plugin: #{msg}"
      return
    end

    # After reload business.
    if p.after_reload(forcing)
      $plugins[pn] = p.class.instance
    else
      p.register_commands
    end
    irc.reply 'Plugin reloaded successfully!'

  end
  help :reload, "Reloads the given plugin. Note that support for this is currently somewhat prelimenary. Use at your own risk. If a plugin refuses to reload, you can pass option -f to make it do so anyway."

  # Unloads a plugin.
  def cmd_unload(irc, plugin)
    if !$user.caps(irc, 'admin', 'owner').any?
      irc.reply "You're not a bot administrator, so don't even start!"
    elsif !plugin or plugin.empty?
      irc.reply "USAGE: unload <plugin name>. Use 'plugin list' to get a list."
    elsif !(p = $plugins[pn = plugin.downcase])
      irc.reply "Plugin not found. Make sure it's in the list given by 'plugin list'."
    else
      p.unregister
      $plugins.delete(pn)
      irc.reply 'Plugin unloaded successfully!'
    end
  end

  # Loads a new plugin.
  def cmd_load(irc, plugin)
    if !$user.caps(irc, 'admin', 'owner').any?
      irc.reply "You're not a bot administrator, so don't even start!"
    elsif !plugin or plugin.empty?
      irc.reply "USAGE: load <plugin name>. This command will not reload an already loaded plugin. Use 'reload' for that."
    elsif $plugins[pn = plugin.downcase]
      irc.reply "That plugin is already loaded!  (To reload it, use the 'reload' command)."
    else
      begin
        if !load_plugin(pn)
          irc.reply "Error loading plugin: File not found in plugin path."
        elsif (klass = self.class.const_get(pn.capitalize))
          ins = klass.instance
          $plugins[ins.name] = ins
          irc.reply 'Plugin loaded successfully!'
        else
          puts "Error loading plugin '#{pn.capitalize}':"
          puts "Couldn't locate plugin class."
          irc.reply "Error loading plugin: Couldn't locate the plugin class."
        end
      rescue Exception => e
        puts "Error loading plugin '#{pn.capitalize}':"
        puts e.message
        puts e.backtrace.join("\n")
        irc.reply "Error loading plugin: #{e.message}"
      end
    end
  end

  def cmd_list(irc, line)
    irc.reply "The following plugins are loaded: \x02#{$plugins.keys.sort.join(', ')}.\x0f"
  end

end

