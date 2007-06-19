
#
# CyBot - IRC module.
#

require 'ircbase/irc'

# Class to interact with IRC from plugins.
class IrcWrapper

  # Private.
  def initialize(from, server, channel = nil)
    @from = from
    @server = server
    @channel = channel
  end

  # Direct reply.
  def privmsg_reply(str)
    @channel ? @channel.privmsg("#{@from.nick}: #{str}") : @from.privmsg(str)
  end
  def notice_reply(str)
    @channel ? @channel.notice("#{@from.nick}: #{str}") : @from.notice(str)
  end

  # Direct response.
  def privmsg_respond(str)
    @channel ? @channel.privmsg(str) : @from.privmsg(str)
  end
  def notice_respond(str)
    @channel ? @channel.notice(str) : @from.notice(str)
  end

  # Reply through default means.
  def reply(str)
    $config['comm/use-notices'] ? notice_reply(str) : privmsg_reply(str)
  end
  def respond(str)
    $config['comm/use-notices'] ? notice_respond(str) : privmsg_respond(str)
  end

  # Direct output.
  def privmsg(str)
    @channel ? @channel.privmsg(str) : @from.privmsg(str)
  end
  def notice(str)
    @channel ? @channel.notice(str) : @from.notice(str)
  end
  def puts(str)
    $config['comm/use-notices'] ? notice(str) : privmsg(str)
  end
  alias_method :say, :puts
  def action(str)
    @channel ? @channel.action(str) : @from.action(str)
  end

  # Access to the rest.
  attr_accessor :from, :channel
  attr_reader :server

end


# Class name must match file name, capitalized if needed.
# A single instance of the class will be created, for now.
# Later, options for per-network or per-channel.

class Irc < PluginBase

  # Fetch a command for execution. Reports errors to the user, and
  # returns nil or [cmd, name, line] if successful.
  def get_command(irc, line)
    cmd_name, line = line.split(' ', 2)
    if cmd_name == '?'
      irc.reply "Type '<plugin name>?' to get brief help and a command list, where <plugin name> is one of: \x02#{$plugins.keys.sort.join(', ')}.\x0f  Also try '<plugin name> <command name>?'."
      return nil
		elsif cmd_name == "help" || cmd_name == "help?" # Don't name a plugin help!
			irc.reply "Try '?' instead of help."
    end
    (help = cmd_name[-1] == ??) and cmd_name.chop!
    cmd = $commands[cmd_name]
    if !cmd or cmd[0] == Plugin::CmdFlag_Multiple
      plugin_name = cmd_name
      unless (plugin = $plugins[plugin_name])
        irc.reply !cmd ? "Unknown command or plugin '#{plugin_name}'." :
          "Command name is ambiguous. Please use the syntax '<plugin> #{cmd_name}' instead, where <plugin> is one of: \x02#{cmd[1..-1].map { |c| c[2].name }.sort.join(', ')}.\x0f"
        return nil
      end
      if help or line == '?'
        irc.reply "#{plugin.brief_help}  Commands: \x02#{plugin.commands.keys.sort.join(', ')}.\x0f"
        return nil
      end
      unless line
        irc.reply "Type '#{plugin_name} <command>', where command is one of: \x02#{plugin.commands.keys.sort.join(', ')}.\x0f  Also try '#{plugin_name}?'."
        return nil
      end
      cmd_name, line = line.split(' ', 2)
      (help = cmd_name[-1] == ??) and cmd_name.chop!
      unless (cmd = plugin.commands[cmd_name])
        irc.reply "No '#{cmd_name}' command in the '#{plugin_name}' plugin.  Try '#{plugin_name}?'."
        return nil
      end
    end
    if help
      irc.reply cmd[3] || 'No help for this command, sorry :-('
      return nil
    end
    [cmd, cmd_name, line]
  end

  class Channel < IRC::Channel

    attr_reader :plugins

    def is_alpha(c)
      c and (c >= ?A && c <= ?Z or c >= ?a && c <= ?z)
    end

    def on_privmsg(from, message)

      # If it's for us, and checks out.
      if message[0] == ?$ and is_alpha(message[1]) || message[1] == ??
        irc = IrcWrapper.new(from, @server, self)
        cmd, cmd_name, line = $irc.get_command(irc, message[1..-1])
        if cmd
          flags, meth, ins = cmd
          begin

            # Security check.
            $user.command_check(irc, ins.name, cmd_name)
            $cmd_cnt += 1

            # Bind and execute!
            line.strip! if line
            if flags & Plugin::CmdFlag_Server != 0
              meth.call(irc, @server, line)
            elsif flags & Plugin::CmdFlag_Channel != 0
              meth.call(irc, self, line)
            else
              meth.call(irc, line)
            end
          rescue Plugin::ParseError => e
            irc.reply e.message
            irc.reply "USAGE: #{cmd_name} #{e.usage}."
          rescue User::SecurityError => e
            irc.reply e.message
          rescue Exception => e
            $log.puts e.message
          end

        end
      end
      call_hooks(:privmsg_chan, from, message)
    end

    def on_notice(from, message)

      if message[0] == ?!
        $log.puts "-- [#{@name}] #{from}: #{message[1..-1]}"
      end

      # Invoke hooks.
      call_hooks(:notice_chan, from, message)

    end

    def on_join(user)
      call_hooks(:join_chan, user)
    end

    def on_topic(user)
      call_hooks(:topic_chan, user, @topic)
    end

    # Called when channel join is done.
    def on_init

      # Request modes from ChanServ, if needed.
      $log.puts "Channel #{@name} joined!"
      if (cs = $config["servers/#{@server.name}/channels/#{@nname}/chanserv"])
        name = $config["servers/#{@server.name}/services/chanserv/name"] || 'ChanServ'
        $log.puts "Requesting modes from #{name}..."
        @server.cmd('PRIVMSG', name, "OP #{@name}") if cs['op']
        @server.cmd('PRIVMSG', name, "VOICE #{@name}") if cs['voice']
      end

      # Call plugin hooks.
      call_hooks(:init_chan)

    end

    def on_part(user)
      call_hooks(:part_chan, user)
    end

    def on_command(handled, from, cmd, *data)
      call_hooks(:command_chan, from, handled, cmd, *data)
    end

    def on_reply(code, *data)
      call_hooks(:reply_chan, nil, code, *data)
    end

    def call_hooks(hook, from = nil, *msg)
      if (h = $hooks[hook])
        irc = nil
        h.each do |i|
          irc ||= IrcWrapper.new(from, @server, self)
          begin
            i[0].call(irc, *msg)
          rescue Exception => e
            $log.puts e.message
            $log.puts e.backtrace.join("\n")
          end
        end
      end
    end

#    def reply_hook(code, *data)
#      super(code, *data)
#  #    $log.puts "[#{@name}] (#{code}) <#{data.length}> #{data.inspect}"
#    end

  end

  class Server < IRC::Server

    def initialize(name, *args)
      super(*args)
      @name = name
    end

    attr_reader :plugins, :name

    def channel_class
      Channel
    end

    def call_hooks(hook, from, *msg)
      if (h = $hooks[hook])
        irc = nil
        h.each do |i|
          irc ||= IrcWrapper.new(from, self)
          begin
            i[0].call(irc, *msg)
          rescue Exception => e
            $log.puts e.message
            $log.puts e.backtrace.join("\n")
          end
        end
      end
    end

    # Called when we're connected.
    # Register with NickServ, if required.
    def on_connect
      $log.puts "Connection to '#{@name}' completed."
      if (ns = $config["servers/#{@name}/services/nickserv"]) and (pw = ns['password'])
        name = ns['name'] || 'NickServ'
        $log.puts "Registering with #{name}..."
        cmd('PRIVMSG', name, 'IDENTIFY', pw)
        cmd('PRIVMSG', name, "IDENTIFY #{pw}")
      end
    end

    def on_privmsg(from, message)
      $log.puts "#{from} told us: #{message.inspect}"

      # Execute command, if authorized. (remove)
      # if (from.nick == 'cryo' or from.nick == 'cyanite') and message[0] == ?&
      #   begin
      #     eval message[1..-1]
      #   rescue Exception => e
      #     $log.puts "Error evaluating code: #{e.message}"
      #   end
      # end

      # Look for command.
      irc = IrcWrapper.new(from, self)
      cmd, cmd_name, line = $irc.get_command(irc, message)
      if cmd
        flags, meth, ins = cmd
        begin

          # Security check.
          $user.command_check(irc, ins.name, cmd_name)
          $cmd_cnt += 1

          # Server-bound command...
          if flags & Plugin::CmdFlag_Server != 0

            # Grab _optional_ server argument.
            # FIXME: Security check.
            if line
              line.strip!
              if line[0] == ?@
                sn, line = line[1..-1].split(' ', 2)
                line.strip! if line
              end
            end

            # Execute.
            if sn
              if (s = $irc.servers[sn])
                meth.call(irc, s, line)
              else irc.reply "Error: The bot isn't connected to the server '#{sn}'."
              end
            else meth.call(irc, self, line)
            end

          # Channel-bound command...
          elsif flags & Plugin::CmdFlag_Channel != 0

            # Grab server/channel arguments.
            if line
              t, line = line.split(' ', 2)
              if t and t[0] == ?@
                sn = t[1..-1]
                t, line = line.split(' ', 2)
              else sn = nil end
              cn = (t and '#&+!'.include?(t[0])) ? t : nil
            else cn = nil end

            # Check if valid. Execute or report error.
            if cn
              if (s = sn ? $irc.servers[sn] : self)
                if (c = s.channels[cn.downcase])
                  line.strip! if line
                  meth.call(irc, c, line)
                else irc.reply "Error: The bot isn't on the channel '#{cn}'."
                end
              else irc.reply "Error: The bot isn't connected to the server '#{sn}'."
              end
            else irc.reply "Error: When invoked in private, this command requires a bot-channel name."
            end

          # Regular (unbound) command...
          else
            line.strip! if line
            meth.call(irc, line)
          end

        rescue Plugin::ParseError => e
          irc.reply e.message
          irc.reply "USAGE: #{cmd_name} #{e.usage}."
        rescue User::SecurityError => e
          irc.reply e.message
        rescue Exception => e
          $log.puts e.message
        end

      end
      call_hooks(:privmsg_priv, from, message)
    end

    def on_notice(from, message)
      $log.puts "#{from} noted: #{message}"
      call_hooks(:notice_priv, from, message)
    end

    def on_command(handled, from, cmd, *data)
      call_hooks(:command_serv, from, handled, cmd, *data)
    end

    def on_reply(code, *data)
      call_hooks(:reply_serv, nil, code, *data)
    end

  end

  def initialize(*args)

    @brief_help = 'Manages IRC connectivity.'
    super(*args)
    @servers = {}
    @start = Time.now
    $irc = self
    $cmd_cnt = 0

    # Common map spaces.
    chan_common = {
      :help => 'Channels this bot should be on, in addition to the global list (irc/channels).',
      :dir => true,
      :skel => {
        :help => 'Channel settings.',
        :dir => true,
        # FIXME: Move to User plugin.
        'enforce' => {
          :help => 'Enforce user capabilities on this channel, changing modes as necessary.',
          :type => Boolean
        },
        'promote' => {
          :help => 'Positively enforce user capabilities on this channel.',
          :type => Boolean
        },
        'demote' => {
          :help => 'Negatively enforce user capabilities on this channel.',
          :type => Boolean
        },
        'user-greeting' => 'Greeting text for users joining the channel.',
        'chanserv' => {
          :help => 'Settings for ChanServ.',
          :dir => true,
          'op' => {
            :help => 'Request and attempt to keep OP on this channel.',
            :type => Boolean
          },
          'voice' => {
            :help => 'Request and attempt to keep VOICE on this channel.',
            :type => Boolean
          }
        }
      }
    }

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
      'plugins' => {
        :dir => true,
        :help => 'Plugin configuration directoy.'
      },
      'irc' => {
        :dir => true,
        :help => 'Global IRC settings.',
        'channels' => chan_common,
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
          'services' => {
            :help => 'Settings for IRC services.',
            :dir => true,
            'nickserv' => {
              :help => 'Settings for identifying with NickServ.',
              :dir => true,
              'name' => 'Nick name of NickServ. Defaults to NickServ.',
              'password' => 'Password used to identify with NickServ.'
            },
            'chanserv' => {
              :help => 'Settings for ChanServ.',
              :dir => true,
              'name' => 'Nick name of ChanServ. Defaults to ChanServ.'
            }
          },
          'channels' => chan_common,
          'user-greeting' => 'Greeting text for users joining a channel.',
        }
      }
    )

    # Make sure we have a default list of nick names.
    nicks = $config['irc/nicks', ['CyBot', '_cybot_', '__cybot']]
    chans = []
    if (chan_dir = $config['irc/channels'])
      chan_dir.each { |k,v| chans << k unless v['autojoin'] == false }
    end

    # Connect to servers in the list.
    if (servs = $config['servers'])
      servs.each do |k,v|

        # Figure out parameters.
        next if !(ac = v['autoconnect']).nil? and ac == false
        host = v['host']  || k
        port = v['port']  || 6667
        nick = v['nicks'] || nicks
        chan = chans.dup
        if (chan_dir = v['channels'])
          chan_dir.each { |ck,cv| chan << ck unless cv['autojoin'] == false }
        end

        # Connect!
        @servers[k] = Server.new(k, host, nick,
          :port => port,
          :user => 'CyBot',
          :channels => chan
        )

      end
    end

  end

  attr_reader :servers

  # We provide some commands as well.

  # Uptime and status.
  def cmd_uptime(irc, line)
    up_for = (Time.now - @start).to_i
    irc.reply "I have been running for #{seconds_to_s(up_for, irc)} during which I processed #{$cmd_cnt} commands."
  end
  help :uptime, 'Displays the current bot uptime.'

  def cmd_version(irc, line)
    irc.action "is an embodiment of CyBot v#{$version}."
  end
  help :version, 'Displays the CyBot release number.'

  def serv_join(irc, serv, line)
    if !$user.caps(irc, 'admin', 'owner').any?
      irc.reply "You need the 'admin' capability for this."
    elsif !line or line.empty?
      irc.reply 'USAGE: join [-]<channel name> [s]'
    else
      chan, sticky = line.split(' ', 2)
      force = false
      if chan[0] == ?-
        chan = chan[1..-1]
        force = true
      end
      chan = '#' + chan unless chan[0] == ?#
      if serv.join(chan, force)
        if sticky and sticky == 's'
          $config["servers/#{serv.name}/channels/#{chan}"] = {}
        end
      elsif !force
        irc.reply "I seem to be already joined to that channel. If you really mean it, use join -<channel name> to make me try to join it anyway."
      end
    end
  end
  help :join, "Makes the bot join a channel. Supply the 's' option to make the join sticky."

  def chan_part(irc, chan, line)
    if !$user.caps(irc, 'admin', 'owner').any?
      irc.reply "You need the 'admin' capability for this."
    else
      line = nil if line and line.empty?
      chan.part(line)
    end
  end
  help :part, 'Makes the bot leave a channel, with an optional reason.'

end

