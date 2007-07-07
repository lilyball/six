#
# IRCBase - A Ruby IRC framework.
#
# Version 0.3 (3)
# Sune Foldager <cryo@diku.dk>
#


module IRC

require 'socket'

# Manages a mask-style IRC address.
class Address

  # Parse a mask.
  def mask=(mask)
    if mask.kind_of? Address
      @nick, @user, @host = mask.nick, mask.user, mask.host
    else
      if mask =~ /^([^!]+)!([^@]+)@(.+)$/
        # Nick/user/host style.
        @nick = $1
        @user = $2
        @host = $3
      elsif mask and mask.include? ?.
        # Host style.
        @user = nil
        @nick = @host = mask
      elsif mask
        # Nick name.
        @user = @host = nil
        @nick = mask
      else
        # Null address.
        @user = @nick = @host = nil
      end
    end
  end

  # Construct object from mask string.
  # e.g. cryo!cryo@cyan-FF40245A.cyanite.org
  def initialize(user_mask, server = nil)
    @server = server
    self.mask = user_mask
  end

  # Access to address parts.
  def mask
    "#{@nick}!#{@user}@#{@host}"
  end
  attr_reader :user, :host, :server
  attr_accessor :nick

  # Normalize a nick name.
  def Address.normalize(nick_name)
    nick_name.to_s.downcase.tr('[]\\', '{}|')
  end

  # Return the normalized nick name.
  def nnick
    Address.normalize(nick)
  end

  # Default string representation is just the nick name.
  def to_s
    @nick
  end

  # Is this a null-address?
  def null?
    not @nick
  end

  # Communication.
  def privmsg(thing)
    @server.privmsg(@nick, thing) if @server
  end
  alias_method :puts, :privmsg
  def notice(thing)
    @server.notice(@nick, thing) if @server
  end
  def action(thing)
    @server.privmsg(@nick, "\1ACTION #{thing}\1")
  end

end

# Class to manage an IRC user •belonging to a channel• (so NOT unique per user).
class User < Address

  # User modes.
  Operator    = 1
  Voice       = 2
  IrcOperator = 4

  # UnrealIRCd also has this:
  Owner       = 256

  # Change the given mode (PRIVATE).
  def change_modes(modes, set_or_clear = true)
    if set_or_clear
      @modes |= modes
    else
      @modes &= ~modes
    end
  end

  def initialize(channel, mask = nil)
    @channel = channel
    super(mask, channel.server)
    @modes = 0
  end

  # External access to modes.
  attr_reader :modes, :channel

  # Channel mode query.
  def op?
    @modes & Operator != 0
  end
  def voice?
    @modes & Voice != 0
  end

  # Channel mode change.
  def op(o = true)
    @channel.op(@nick, o)
  end
  def deop
    @channel.op(@nick, false)
  end
  def voice(v = true)
    @channel.voice(@nick, v)
  end
  def unvoice
    @channel.voice(@nick, false)
  end

end

# Class to manage an IRC channel.
class Channel

  # Modes.
  Anonymous     =   1
  InviteOnly    =   2
  Moderated     =   4
  NoMessages    =   8
  Quiet         =  16
  Private       =  32
  Secret        =  64
  ReOp          = 128
  TopicOpOnly   = 256

  # Don't call this directly.
  def initialize(server, channel_name)

    # Initialize a lot of stuff.
    @server = server
    @name = channel_name
    @nname = channel_name.downcase
    @users = {}
    @bans = []
    @exceptions = []
    @invites = []
    @modes = 0
    @limit = 0
    @booting = true
    $log.puts "Channel joined: #{channel_name}"

    # Issue some commands.
    server.cmd('MODE', channel_name)
    server.cmd('WHO', channel_name)

  end

  # Reader for various things.
  attr_reader :server, :modes, :users, :name, :nname, :limit, :password, :bans, :exceptions, :invites, :me
  attr_reader :booting, :topic, :old_topic

  # Channel IO.
  def write(thing)
    @server.cmd('PRIVMSG', @name, thing.to_s)
  end
  def printf(format, *stuff)
    write(sprintf(format, *stuff))
  end
  def putc(char)
    write(char.kind_of(Integer?) ? char.chr : char.to_s[0..0])
  end
  alias_method :print, :write
  alias_method :privmsg, :write
  alias_method :puts, :write

  def notice(thing)
    @server.cmd('NOTICE', @name, thing.to_s)
  end

  # CTCP actions.
  def action(thing)
    @server.cmd('PRIVMSG', @name, "\1ACTION #{thing}\1")
  end

  # Channel mode changes.
  # Op and voice don't check if the nicks are actually joined. To make sure,
  # use them on the User object instead (from the 'nicks' map).
  def mode(string, *args)
    @server.cmd('MODE', @name, string, *args)
  end
  def op(nick, o = true)
    mode(o ? '+o' : '-o', nick)
  end
  def voice(nick, v = true)
    mode(v ? '+v' : '-v', nick)
  end

  # User hooks.
  def on_privmsg(from, message)
  end
  def on_notice(from, message)
  end
  def on_join(user)
  end
  def on_init
  end
  def on_part(user)
  end

  # Previous and current topic is available in @old_topic and @topic.
  def on_topic(user)
  end

  # Called on all commands. 'handled' means a hook was already called.
  def on_command(handled, from, cmd, *data)
  end

  # Called on all replies.
  def on_reply(code, *data)
  end

  # Called from the server to notify us of a nick name change.
  def nick_change(from, to)
    if (u = @users.delete(from.nnick))
      u.nick = to
      @users[u.nnick] = u
#      $log.puts "Nick change in #{@name}: #{from.nick} => #{to}"
#      $log.puts @users.keys.join(', ')
    end
  end

  # Debug thingie.
  def dump_users
    $log.puts("-- Users: " + @users.keys.map { |k| "#{k} (#{@users[k].modes})" }.join(', '))
  end

  # Part the channel, with an optional reason.
  def part(reason = nil)
    if reason
      @server.cmd('PART', @name, reason)
    else
      @server.cmd('PART', @name)
    end
  end

  # Internal mode parser.
  def parse_modes(modes)
    i = 1
    set = (modes[0][0] == ?+)
    modes[0][1..-1].each_byte { |m|
  
      case m

      # Give "channel creator" status;
      when ?O
        # Not supported.
        i += 1

      # Give/take channel operator privilege;
      when ?o
        if (u = @users[Address.normalize(modes[i])])
          u.change_modes(User::Operator, set)
        end
        i += 1

      # Give/take the voice privilege;
      when ?v
        if (u = @users[Address.normalize(modes[i])])
          u.change_modes(User::Voice, set)
        end
        i += 1

      # Toggle the anonymous channel flag;
      when ?a
        @modes = set ? (@modes | Anonymous) : (@modes & ~Anonymous)

      # Toggle the invite-only channel flag;
      when ?i
        @modes = set ? (@modes | InviteOnly) : (@modes & ~InviteOnly)

      # Toggle the moderated channel;
      when ?m
        @modes = set ? (@modes | Moderated) : (@modes & ~Moderated)

      # Toggle the no messages to channel from clients on the outside;
      when ?n
        @modes = set ? (@modes | NoMessages) : (@modes & ~NoMessages)

      # Toggle the quiet channel flag;
      # On UnrealIRCd this is instead a channel-user flag meaning: Channel owner.
      # On Freenode this works like ban, but is fortunately never sent.
      # FIXME: Make it magically work in Unreal also :-/.
      when ?q
        @modes = set ? (@modes | Quiet) : (@modes & ~Quiet)

      # Toggle the private channel flag;
      when ?p
        @modes = set ? (@modes | Private) : (@modes & ~Private)

      # Toggle the secret channel flag;
      when ?s
        @modes = set ? (@modes | Secret) : (@modes & ~Secret)

      # Toggle the server reop channel flag;
      when ?r
        @modes = set ? (@modes | ReOp) : (@modes & ~ReOp)

      # Toggle the topic settable by channel operator only flag;
      when ?t
        @modes = set ? (@modes | TopicOpOnly) : (@modes & ~TopicOpOnly)

      # Set/remove the channel key (password);
      when ?k
        @password = set ? modes[i] : nil
        i += 1

      # Set/remove the user limit to channel;
      when ?l
        if set
          @limit = modes[i].to_i
          i += 1
        else @limit = 0
        end

      # Set/remove ban mask to keep users out;
      when ?b
        if set: @bans << modes[i] unless @bans.include? modes[i]
        else    @bans.delete modes[i]
        end
        i += 1

      # Set/remove an exception mask to override a ban mask;
      when ?e
        if set: @exceptions << modes[i] unless @exceptions.include? modes[i]
        else    @exceptions.delete modes[i]
        end
        i += 1

      # Set/remove an invitation mask to automatically override the invite-only flag;
      when ?I
        if set: @invites << modes[i] unless @invites.include? modes[i]
        else    @invites.delete modes[i]
        end
        i += 1

      end
    }
  end

  # Low-level hooks.
  def command_hook(from, cmd, *data)

    user = @users[from.nnick] || from
    handled = case cmd

    # Topic system.
    when 'TOPIC'
      @old_topic = @topic
      @topic = data[0]
      on_topic(user)
      true

    # Message to channel.
    when 'PRIVMSG'
      on_privmsg(user, data[0])
      true

    # Notice to channel.
    when 'NOTICE'
      on_notice(user, data[0])
      true

    # A user joined us.
    when 'JOIN'
      @users[from.nnick] = (user = User.new(self, from))
      on_join(user)
      true

    # A user left us, or we left ourselves.
    when 'PART', 'QUIT'
      if from.nnick == @me.nnick
        on_part(@me)
        @server.parted(self)
      else
        user = @users.delete from.nnick
        on_part(user || from)
      end
      true

    # A user was kicked out.
    when 'KICK'
      @users.delete(Address.normalize(data[0]))
      false

    # Channel modes changed.
    when 'MODE'
      parse_modes(data)
      false

    # Otherwise, mark as unhandled.
    else false
    end

    # General command hook.
    on_command(handled, user, cmd, *data)

  end

  # Helper for NAMES and WHO list, to adjust user modes.
  # FIXME: Use the nick_prefixes thingy here.
  def adjust_modes(user, mode_char)
    case mode_char
    when ?~
      user.change_modes(User::Owner, true)
    when ?@
      user.change_modes(User::Owner, false)
      user.change_modes(User::Operator, true)
    when ?+
      user.change_modes(User::Owner, false)
      user.change_modes(User::Operator, false)
      user.change_modes(User::Voice, true)
    end
  end

  def reply_hook(code, *data)

    case code

    # Channel topic.
    when Server::Rpl::Topic
      @old_topic = @topic
      @topic = data[1]
      on_topic(nil)

    # NAMES list. Let's collect.
    when Server::Rpl::NamesList

      @_names ||= {}
      codes, modes = @server.nick_prefixes
      data[2].split(' ').each do |n|

        # Figure out modes to change.
        if (ci = codes.index(n[0]))
          n = n[1..-1]
        else ci = nil end

        # Store name and fix up modes.
        nn = Address.normalize(n)
        @_names[nn] = true
        u = @users[nn] or @users[nn] = (u = User.new(self, n))
        @me = u if nn == @server.nnick
        adjust_modes(u, ci) if ci # FIXME, use modes.
      end

    # End of NAMES list. Clear out spurious users.
    when Server::Rpl::EndOfNames
      @users.delete_if { |k,v| !@_names[k] }
      @_names = nil

    # (Partial) channel modes.
    when Server::Rpl::ChannelModes
      parse_modes(data[1..-1])
      $log.puts("==> Modes for #{@name}: #{@modes}")

    # Who list. Collect like NAMES.
    when Server::Rpl::WhoList
      unless @_who
        @_whoRE =
          Regexp.compile('([A-Za-z]+)(\*)?([' + Regexp.escape(@server.nick_prefixes[0]) + '])?')
        @_who = {}
      end
      nick = data[4]
      nnick = Address.normalize(nick)
      @_who[nnick] = true
      mask = "#{nick}!#{data[1]}@#{data[2]}"
      if (u = @users[nnick])
        u.mask = mask
      else
        u = User.new(self, mask)
        @users[nnick] = u
      end
      if data[5] =~ @_whoRE
        adjust_modes(u, $3[0]) if $3 # FIXME: use modes
        u.change_modes(User::IrcOperator, $2)
      end

    # Remove spurious users and call init hook.
    when Server::Rpl::EndOfWho
      @users.delete_if { |k,v| !@_who[k] }
      dump_users
      @_who = @_whoRE = nil
      if @booting
        on_init
        @booting = false
      end

    # Ban list.
    when Server::Rpl::BansList
      @_bans ||= []
      @_bans << data[1]
    when Server::Rpl::EndOfBans
      @bans = @_bans
      @_bans = nil

    # Exception list.
    when Server::Rpl::ExceptionsList
      @_except ||= []
      @_except << data[1]
    when Server::Rpl::EndOfExceptions
      @exceptions = @_except
      @_except = nil

    # Invites list.
    when Server::Rpl::InvitesList
      @_invs ||= []
      @_invs << data[1]
    when Server::Rpl::EndOfInvites
      @invites = @_invs
      @_invs = nil

    end

    # General reply hook.
    on_reply(code, *data)

  end

end

# Class to manage the connection to an IRC server.
class Server

  # Global connection list.
  @@servers = []

  # Modes
  Away            =  1
  Invisible       =  2
  Wallops         =  4
  Restricted      =  8
  Operator        = 16
  LocalOperator   = 32
  ServerNotices   = 64

  # States
  module State

    Connecting  = 0     # Connecting to server.
    Failed      = 1     # Connection lost or failed.
    Running     = 2     # Running in the main loop.
    Quitting    = 3     # Disconnecting.
    Closed      = 4     # Successfully closed.

  end

  # Connects to the network:
  #   server_host:  Host address.
  #   nicks:        Either a string or an array of prefered nicks.
  #   options:
  #     port:       Server port. Defaults to 6667.
  #     user:       User name. Defaults to 'ircbase'.
  #     password:   Password, if needed.
  #     channels:   Channels to initially join.
  #
  def initialize(server_host, nicks, options = {})

    # Set options and other stuff.
    @@servers << self
    @state = State::Connecting
    set_options(options)
    @host = server_host
    @nicks = nicks.to_a
    @modes = 0
    @channels = {}
    @nick_prefixes = ['@+', 'ov']

    # Start main thread and return.
    @initial_channels = options[:channels]
    @recv_thread = Thread.new do
      begin
        recv_main
      rescue Exception => e
        $log.puts e.message
        $log.puts e.backtrace.join("\n")
      end
    end
  end

  # Some external access.
  attr_reader :channels, :nick, :nnick, :nick_prefixes

  # Wait for connection to close (for the thread to exit).
  def wait
    @recv_thread.join if @recv_thread
  end

  # Wait for ALL connections to close.
  # BUG: Doesn't work if servers are added after calling this. Fix it :-p.
  def Server.wait
    @@servers.dup.each { |s| s.wait }
  end
  def wait_all
    Server.wait
  end

  # Quit all connections.
  def Server.quit(reason = nil)
    @@servers.dup.each { |s| s.quit(reason) }
  end
  def quit_all(reason = nil)
    Server.quit(reason)
  end

  # Types for the receive hook. FIXME: VERY DEPRECATED!!!
  module Type

    Init      = 0       # Sent before connecting the first time.
    Connect   = 1       # Sent before each connection attempt.
    Done      = 2       # Sent when done; no more reconnection attempts.

    Numeric   = 3       # Numeric response. Data: [from, code, arguments...].
    PrivMsg   = 4       # Private message. Data: [from, to, message].
    Notice    = 5       # Notice. Data: [from, to, message].
    Quit      = 6       # Quit message from the server. Data: [from].
    Command   = 7       # Non-numeric command, not in the list above.
                        # Data: [from, command, arguments...].

  end

  # Returns the channel class. Override for custom channels.
  def channel_class
    Channel
  end

  # Override these.
  def on_privmsg(from, message)
  end
  def on_notice(from, message)
  end
  def on_connect
  end

  # Called on all commands. 'handled' means a hook was already called.
  def on_command(handled, from, cmd, *data)
  end

  # Called on all replies.
  def on_reply(code, *data)
  end

  def parse_modes(modes)
    set = (modes[0] == ?+)
    modes[1..-1].each_byte { |m|
      case m

      # User is flagged as away;
      when ?a
        @modes = set ? (@modes | Away) : (@modes & ~Away)

      # Marks a users as invisible;
      when ?i
        @modes = set ? (@modes | Invisible) : (@modes & ~Invisible)

      # User receives wallops;
      when ?w
        @modes = set ? (@modes | Wallops) : (@modes & ~Wallops)

      # Restricted user connection;
      when ?r
        @modes = set ? (@modes | Restricted) : (@modes & ~Restricted)

      # Operator flag;
      when ?o
        @modes = set ? (@modes | Operator) : (@modes & ~Operator)

      # Local operator flag;
      when ?O
        @modes = set ? (@modes | LocalOperator) : (@modes & ~LocalOperator)

      # Marks a user for receipt of server notices.
      when ?s
        @modes = set ? (@modes | ServerNotices) : (@modes & ~ServerNotices)

      end
    }
  end

  # BEGIN: Override these if you need advanced control.

  def privmsg_hook(from, to, message)

    # If message is to a channel, redirect.
    if to[0] == ?# or to[0] == ?&
      chan = @channels[to.downcase] and chan.on_privmsg(from, message)

    # Otherwise it's probably private. Yay!
    elsif Address.normalize(to) == @nnick
      on_privmsg(from, message)
    end

  end

  def notice_hook(from, to, message)

    # If notice is to a channel, redirect.
    if to[0] == ?# or to[0] == ?&
      chan = @channels[to.downcase] and chan.on_notice(from, message)

    # Otherwise it's probably private. Yay!
    elsif Address.normalize(to) == @nnick
      on_notice(from, message)
    end

  end

  def reply_hook(code, to, *data)

    # If the reply isn't for us, something is wrong. Skip for now.
    return unless Address.normalize(to) == @nnick

    # Is the reply for a channel we're in? If yes forward.
    if  ((code == Rpl::NamesList and data[0].length == 1 and
        (data[0][0] == ?= or data[0][0] == ?* or data[0][0] == ?@) and chan = data[1]) or
        chan = data[0]) and (chan[0] == ?# or chan[0] == ?&) and c = @channels[chan.downcase]
      c.reply_hook(code, *data)
      return
    end

    # Otherwise, parse!
    case code

    # If it's our modes, parse them.
    when Rpl::UserModes
      parse_modes(data[0])

    # Server capability list (really a bounce, but that's not used anymore).
    when Rpl::Bounce
      data.each do |w|
        if w =~ /^([A-Z]+)=(.*)$/
          key, val = $1, $2
          case key

          # Nick name prefixes and their modes.
          when 'PREFIX'
            if val =~ /^\((.*)\)(.*)$/
              @nick_prefixes = $2, $1
            end

          end
        end
      end

    end

    # General reply hook.
    on_reply(code, *data)

  end

  def command_hook(type, from, cmd, name = nil, *data)

    # If it's for a channel, see if we have it. If yes, forward and we're done.
    if name and (name[0] == ?# or name[0] == ?&) and (chan = @channels[name.downcase])
      chan.command_hook(from, cmd, *data)

    # If not for an existing channel, decode it.
    else

      # Major debug spam.
#      $log.puts "irc> #{from.mask} #{cmd} #{name} #{data.join(' ') if data}"

      nname = Address.normalize(name)
      handled = case cmd

      # Private message.
      when 'PRIVMSG'
        on_privmsg(from, data[0]) if nname == @nnick
        true

      # Private notice.
      when 'NOTICE'
        on_notice(from, data[0]) if nname == @nnick
        true

      # We joined a new channel.
      when 'JOIN'
        dname = name.downcase
        if from and from.nnick == @nnick
          unless @channels.has_key? dname
            chan = channel_class.new(self, name)
            @channels[dname] = chan
            chan.command_hook(from, cmd, *data)
          end
        end
        true

      # Someone changed their nick name. Propagate to channels.
      when 'NICK'
        @channels.each_value { |chan| chan.nick_change(from, name) }
        true

      # If we get a ping, then pong back!
      when 'PING'
        cmd('PONG', name, *data)
        true

      # We changed our user modes.
      when 'MODE'
        next unless nname == @nnick
        parse_modes(data[0])
        true

      # Otherwise, mark as unhandled.
      else false
      end

      # General command hook.
      on_command(handled, from, cmd, name, *data)

    end
  end

  # END: Override these if you need advanced control.

  # Send a message.
  def privmsg(to, thing)
    cmd('PRIVMSG', to, thing.to_s)
  end

  # Or a notice.
  def notice(to, thing)
    cmd('NOTICE', to, thing.to_s)
  end

  # Or a CTCP action.
  def action(to, thing)
    cmd('PRIVMSG', to, "\1ACTION #{thing}\1")
  end

  # Sends a line to the server.
  def send(line)
    @sock.print(line, "\r\n")
  end

  # Sends a command to the server.
  def cmd(command, *options)
    return false unless @state == State::Running
    line = command
    line << ' ' << (options[0...-1].join ' ') if options.length > 1
    line << ' :' << options[-1].to_s if options.length > 0
    send line
#    $log.puts "->- #{line}"
  end

  # Request disconnection from the server.
  def quit(reason = nil)
    @state = State::Quitting
    @options[:auto_reconnect] = false
    reason ? internal_cmd('QUIT', reason) : internal_cmd('QUIT')
  end

  # Join a channel.
  def join(channel, force = false)
    return false if channels[channel] and !force
    cmd('JOIN', channel)
    true
  end

  # Parts a channel. Returns true if ok, false if channel didn't seem to be joined.
  # The 'force' argument can be used to send the PART anyway.
  def part(channel, reason = nil, force = false)
    if channel.kind_of? Channel
      channel.part(reason)
    else
      unless (c = @channels[channel.downcase])
        return false unless force
        if reason
          cmd('PART', channel, reason)
        else
          cmd('PART', channel)
        end
      end
      c.part(reason)
    end
    true
  end

  # Called from the channel when it is parted or similar. Internal use only.
  def parted(chan)
    @channels.delete chan.name.downcase
  end

  # Returns the server host.
  attr_reader :host, :modes

  # Returns the current state.
  attr_reader :state

  # Returns the server port.
  def port
    @options[:port]
  end

  # Process a command line as if it were received from the network. Returns an array:
  # [prefix, command, [arguments...], or nil on failure.
  #
  def process_command(line)

    # Parse: [:prefix] command arguments* [:]last_argument
    return nil unless line =~ /^(?::([^ ]+) )?([^ ]+)(?: (.+))?\r$/

    # Parse arguments...
    pre, cmd, arg = $1, $2, $3
    if arg
      if arg[0] == ?:
        args = arg[1..-1].to_a
      else
        if i = arg.index(' :')
          last = arg[(i+2)..-1]
          arg = arg[0...i]
        end
        args = arg.split ' '
        args << last if i
      end
    else
      args = nil
    end

    # Invoke hook and return.
    addr = Address.new(pre, self)
    if cmd =~ /\d{3}/
      reply_hook(cmd.to_i, *args)
    else
      command_hook(Type::Command, addr, cmd, *args)
    end
    [addr, cmd, args]

  end

  # Numeric command types.
  module NumericType
    Client  = 0
    Reply   = 1
    Error   = 2
    Other   = 3
  end

  # Numeric codes: ERR.
  module Err
    NoNickNameGiven     = 413
    NickNameInUse       = 433
    ErroneusNickName    = 432
    NickCollision       = 436
    UnavailResource     = 437
  end

  # Numeric codes: RPL.
  module Rpl
    Welcome         =   1
    Bounce          =   5
    UserModes       = 221
    ChannelModes    = 324
    NoTopic         = 331
    Topic           = 332
    TopicSetBy      = 333
    InvitesList     = 346
    EndOfInvites    = 347
    ExceptionsList  = 348
    EndOfExceptions = 349
    WhoList         = 352
    EndOfWho        = 315
    NamesList       = 353
    EndOfNames      = 366
    BansList        = 367
    EndOfBans       = 368
  end

  # Determines the type or category of 3-digit command.
  def dc_type(code)
    case code
      when 0...100:   NumericType::Client
      when 200...400: NumericType::Response
      when 400...600: NumericType::Error
      else            NumericType::Other
    end
  end




private

  # Internal send-command. No checks.
  def internal_cmd(command, *options)
    line = command
    line << ' ' << (options[0...-1].join ' ') if options.length > 1
    line << ' :' << options[-1].to_s if options.length > 0
    $log.puts '>>> ' + line
    send line
  end

  # Sets default options, and adjusts some values.
  def set_options(options)

    # Set defaults and merge in the user supplied ones.
    @options = {
      :port       => 6667,
      :user       => 'ircbase',
      :realname   => 'IRCBase v0.1'
    }
    @options.merge! options

    # Do some post-processing.
    @options[:port] = @options[:port].to_i

  end

  # Main connection and receiver loop.
  def recv_main

    # Re-connect loop.
#    command_hook(Type::Init)
    begin

      # Rescue block.
#      command_hook(Type::Connect)
      begin

        # Connect...
        ok = false
        command = []
        nick_errors = [
          Err::NoNickNameGiven,
          Err::NickNameInUse,
          Err::ErroneusNickName,
          Err::NickCollision,
          Err::UnavailResource
        ]
        @sock = TCPSocket.new(host, port)

        # Try login with each nick in turn...
        user_done = false
        @nicks.each do |nick|

          # Login.
          internal_cmd('NICK', nick)
          unless user_done
            internal_cmd('USER', @options[:user], '8', '*', @options[:realname])
            user_done = true
          end

          # Now deal with errors or success.
          c = nil
          while(line = @sock.gets)
            c = process_command(line)
            next if (code = c[1].to_i) == 0
            next if nick_errors.include? code  # FIXME <- wrong next. re cast this stuff.
            next unless code == Rpl::Welcome or dc_type(code) == NumericType::Error
            ok = true if code == Rpl::Welcome
            break
          end

          @nick = c[2][0] if c
          @nnick = Address.normalize(@nick)
          break

        end

        # If something failed, send QUIT and bail out. Otherwise, grab nick-name.
        unless ok
          internal_cmd('QUIT')
          raise SocketError.new("Protocol error.")
        end

        # Alright, we're logged in.
        @state = State::Running

        # Deal with on-connect channels, if any.
        if @initial_channels
          @initial_channels.each { |ch| cmd('JOIN', ch) }
          @initial_channels = nil
        end

        # Main loop.
        on_connect
        begin
          while(line = @sock.gets)
            process_command(line)
          end
        rescue SocketError => e
          $log.puts "Terminating server on '#{@host}:#{@port}' due to socket error: #{e.message}"
          @state = State::Failed
          raise
        end

      # Any socket error is considered fatal.
      rescue SocketError => e
        unless @state == State::Failed
          @state = State::Failed
          $log.puts "Error connecting to '#{@host}:#{@port}': #{e.message}"
        end
      rescue Exception => e
        unless @state == State::Failed
          @state = State::Failed
          $log.puts e.message
          $log.puts e.backtrace.join("\n")
        end

      ensure
        @sock.close if @sock

      end


    end while ok and @options[:auto_reconnect]
    Thread.current[:done] = true
    @state = State::Closed if ok
    @@servers.delete self

  end

end

end

