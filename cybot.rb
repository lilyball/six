
#
# CyBot.
#

# Some modules we need.
puts 'CyBot v0.2 starting up...'
require 'thread'
require 'pluginbase'
require 'configspace/configspace'


# =====================
# = Plugin management =
# =====================

# Root plugins. We always need these.
RootPlugins = ['plugin', 'irc', 'user', 'test']

# Provide a namespace for plugins.
module Plugins
end

# Tries to load the named plugin.
# Should reload if already loaded.
# Names are lower-case or properly cased?.
# RAISES: LoadError, PluginError.
def load_plugin(name)

  # FIXME: Have a few places to look.

  begin

    # Try to load.
    n = name.downcase
    Plugins.module_eval { load("lib/#{n}.rb") }

    # Find the class.
    if (klass = self.class.const_get(n.capitalize))

      # Initialize it.
      ins = klass.shared_instance
      $plugins[ins.name] = ins
      puts "Core plugin '#{ins.name.capitalize}' loaded."

    else
      puts "Error loading core plugin '#{n.capitalize}':"
      puts "Couldn't locate plugin class."
    end

  rescue Exception => e
    puts "Error loading core plugin '#{n.capitalize}':"
    puts e.message
    puts e.backtrace.join("\n")
  end

end

# Some global maps.
$commands  = {}
$hooks     = {}
$plugins   = {}

# Load global configuration.
$config = ConfigSpace.new(ARGV[0]) or return 1
$config.prefix = <<EOS
# CyBot 0.2 main configuration file. Be careful when editing this file manually,
# as it is automatically saved run-time. On-line edit is recomended.
EOS

# Save everything.
@save_all_mutex = Mutex.new
def save_all(quiet = false)
  @save_all_mutex.synchronize do
    puts 'Saving plugin data...' unless quiet
    $plugins.each do |n,p|
      begin
        print "  #{n}... " unless quiet
        p.save
        puts "Ok" unless quiet
      rescue Exception => e
        puts "Failed with error: #{e.message}" unless quiet
      end
    end
    puts 'Saving global configuration...' unless quiet
    $config.save
  end
end

# Handler on ctrl-c at this point.
Signal.trap 'INT' do
  Signal.trap 'INT', 'DEFAULT'
  puts 'Shutdown in progress. Press ctrl-c again to abort immediately.'
  puts 'Asking IRC handlers to quit...'
  IRC::Server.quit('Ctrl-c pressed on console...')
end

# Load root plugins.
$: << File.expand_path('support')
RootPlugins.each { |name| load_plugin(name) }
$plugins.each_value do |plugin|
  plugin.on_startup if plugin.respond_to? :on_startup
end

# Set up timer to save data on regular intervals.
Thread.new do
  loop do
    sleep(60*60)
    save_all(true)
  end
end

# Done. Wait for quit.
puts 'Startup complete!'
IRC::Server.wait

# Tell all plugins to save, and then save the main config.
puts 'Preparing to exit...'
save_all
puts 'All done, see you next time.'

