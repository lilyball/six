#
# CyBot - User management.
#

require 'digest/sha1'


# Neat array stuff.
class Array

  # Matching hostmasks.
  def include_mask?(str)
    each do |e|
      if e.include? ?*
        re = Regexp.new(e.gsub('.', '\.').gsub('*', '.*'))
        rc = re =~ str
        return rc if rc
      else
        return true if e == str
      end
    end
    false
  end

end



class User < PluginBase

  # Settings that are considered capabilities.
  CapsList = ['owner', 'admin', 'op', 'voice', 'greet']

  # Called from other plugins.
  def add_caps(*caps)
    CapsList.concat caps
  end


  # Security error.
  class SecurityError < Exception
  end

  def initialize

    @brief_help = 'Manages registrated bot users.'
    super

    @ident_thread = nil
    @ident_in_progress = nil
    
    @ident_queue = [] unless @ident_queue
    
    @active_users = {}
    
    # Keeps state from start of WHOIS to end of NickServ INFO when identifying a user.
    @whois = {}
    @whoisidentified_code = {}
    
    if (cfg = $config['servers'])
      cfg.each do |name, serv|
        if (c = serv['services']) and (c = c['nickserv']) and (c = c['whois-code'])
          @active_users[name] = {}
          @whois[name] = {}
          @whoisidentified_code[name] = c
        end
      end
    end

    # Set global variable.
    @servers = {}
    $user = self

    # Other plugins can add methods to this. It's important to remember to
    # remove them again, before unload/reload. Method will be called like this:
    # hook(seen_or_lost, irc_wrapper, user_nick)
    @user_watch_hooks = []

    # Commons.
    op_com = {
      :type => Boolean,
      :help => 'User may become channel operator.'
    }
    voice_com = {
      :type => Boolean,
      :help => 'User may gain voice.'
    }
    owner_com = {
      :type => Boolean,
      :help => 'User is bot owner.'
    }
    admin_com = {
      :type => Boolean,
      :help => 'User is bot administrator.'
    }
    greet_com = {
      :type => Boolean,
      :help => 'User may set a greeting.'
    }
    cmds_com = {
      :type => Array,
      :help => 'Command filters.'
    }
    plug_com = {
      :type => Array,
      :help => 'Plugin filters.'
    }

    # Config space addition.
    $config.merge(
      'irc' => {
        :dir => true,
        'track-nicks' => {
          :help => 'Track nick name changes when identified.',
          :type => Boolean
        },
        'defaults' => {
          :dir => true,
          :help => 'Default user capabilities.',
          'op' => op_com,
          'voice' => voice_com,
          'owner' => owner_com,
          'admin' => admin_com,
          'greet' => greet_com,
          'commands' => cmds_com,
          'plugins' => plug_com
        }
      },
      'servers' => {
        :dir => true,
        :skel => {
          :dir => true,
          'defaults' => {
            :dir => true,
            :help => 'Default capabilities for all users on this server.',
            'op' => op_com,
            'voice' => voice_com,
            'owner' => owner_com,
            'admin' => admin_com,
            'greet' => greet_com,
            'commands' => cmds_com,
            'plugins' => plug_com
          },
          'users' => {
            :help => 'User list for this server.',
            :dir => true,
            :skel => {
              :help => 'User settings.',
              :dir => true,
              'op' => op_com,
              'voice' => voice_com,
              'owner' => owner_com,
              'admin' => admin_com,
              'greet' => greet_com,
              'commands' => cmds_com,
              'plugins' => plug_com,
              'fuzzy-time' => {
                :type => Boolean,
                :help => 'If set, time durations will be given in a more fuzzy format.'
              },
              'auth' =>
                "The security level used when authenticating the user. One of 'hostmask', 'trusted' and 'manual'.",
              'channels' => {
                :dir => true,
                :help => 'User capabilities for various channels.',
                :skel => {
                  :dir => true,
                  'op' => op_com,
                  'voice' => voice_com,
                  'greet' => greet_com,
                  'greeting' => "Greeting text for this channel. Ignored unless user has the 'greet' capability."
                }
              },
              'masks' => {
                :help => "Host masks for this user.",
                :type => Array
              },
              'password' => 'Password for identification.',
              'flags' => {
                :help => 'User flags.',
                :type => Array,
                :on_change => ConfigSpace.set_semantics(['secure', 'foo', 'bar'])
              },
            }
          },
          'channels' => {
            :dir => true,
            :skel => {
              :dir => true,
              'defaults' => {
                :dir => true,
                :help => 'Default user capabilities for this channel.',
                'op' => op_com,
                'voice' => voice_com
              }
            }
          }
        }
      })

  end

  attr_reader :user_watch_hooks

  # Retrieve the nick name of the given recognized user, which could be different
  # from the given nick if nick tracking is enabled. Returns nil if user is not
  # known. If passed an IrcWrapper, a server name need not be given. Server name
  # can itself be an IrcWrapper.
  def get_nick(irc, sn = nil)
    if sn: sn = sn.server.name if sn.kind_of?(IrcWrapper)
    else sn = irc.server.name end
    if irc.kind_of?(String)
      nn = irc
      irc = nil
    else nn = irc.from.nick end
    if !(s = @active_users[sn]) or !(u = s[IRC::Address.normalize(nn)])
      irc.reply "Do I know you?  At least not right now." if irc
      nil
    else (u == true) ? nn : u end
  end

  # Retrieve the user data for the given user. Real user names must be used, which
  # is not necessarily the current nick of the user. Use get_nick above to resolve
  # that, if needed. User can be given as an IrcWrapper.
  def get_data(user, sn = nil)
    if user.kind_of?(IrcWrapper)
      nn = user.from.nick
      if (s = @active_users[sn = user.server.name]) and (s = s[IRC::Address.normalize(nn)])
        rn = (s == true) ? nn : s
        [rn, $config["servers/#{sn}/users/#{IRC::Address.normalize(rn)}"]]
      else
        user.reply "Do I know you?  At least not right now."
        nil
      end
    else
      sn = sn.server.name if sn.kind_of?(IrcWrapper)
      $config["servers/#{sn}/users/#{IRC::Address.normalize(user)}"]
    end
  end

  # Get user if he's known (returns the real nickname).
  # Argument can be an IrcWrapper or a name. The latter form will
  # fail silently, and needs a server name passed in.
  def get_user(irc, sn = nil)
    sn = irc.server.name unless sn
    if irc.kind_of?(String)
      nn = irc
      irc = nil
    else
      nn = irc.from.nick
    end
    if !(s = @active_users[sn]) or !(u = s[IRC::Address.normalize(nn)])
      irc.reply "You're not identified." if irc
      nil
    else
      (u == true) ? nn : u
    end
  end

  # Get user data or report the error and fail. Same usage as above.
  def get_user_data(irc, sn = nil)
    sn = irc.server.name unless sn
    if irc.kind_of?(String)
      nn = irc
      irc = nil
    else
      nn = irc.from.nick
    end
    if !(s = @active_users[sn]) or !(u = s[IRC::Address.normalize(nn)])
      irc.reply "You're not identified." if irc
    else
      rn = (u == true) ? nn : u
      if !(ud = $config["servers/#{sn}/users/#{IRC::Address.normalize(rn)}"])
        irc.reply "Error accessing user data. Get a hold of the bot owner." if irc
      else
        return ud, rn
      end
    end
    nil
  end

  # Who am I?
  def cmd_whoami(irc, line)
    if (rn = get_nick(irc))
      if IRC::Address.normalize(rn) == irc.from.nnick
        irc.reply "Why you're \x02#{rn}\x0f of course, silly :-)."
      else
        irc.reply "Weeell.. looks like you're \x02#{rn}\x0f disguised as \x02#{irc.from.nick}\x0f, you sneaky thing you!"
      end
    end
  end
  help :whoami, 'Displays whether or not I know you, including if I am tracking you after a nick change.'

  # Who are we all?
  def chan_whoarewe(irc, chan, line)
    if (s = @active_users[irc.server.name])
      nicks = []
      s.each do |k,v|
        nicks << ((v == true) ? k : "#{k} (#{v})") if chan.users.has_key? k
      end
      unless nicks.empty?
        irc.reply "I know these people: #{nicks.join(', ')}."
        return
      end
    end
    irc.reply "I don't know anyone here :-("
  end
  help :whoarewe, 'Displays a list of all currently identified users in the channel.'

  # Hostmasks for this user.
  def cmd_hostmask(irc, line)
    irc.reply "Your current hostmask is #{irc.from.mask}"
  end
  help :hostmask, 'Displays your current hostmask.'

  def cmd_hostmasks(irc, line)
    rn, ud = get_data(irc)
    return unless ud
    if (m = ud['masks'])
      i = 0;
      masks = m.map { |e| i += 1; "[#{i}] #{e}" }.join(', ')
      nn_str = " #{rn}" if IRC::Address.normalize(rn) != irc.from.nnick
      irc.reply "The following hostmasks are assigned to you#{nn_str}: #{masks}"
    else
      irc.reply "You have no hostmasks assigned to you."
    end
  end
  help :hostmasks, 'For identified users, displays your list of allowed hostmasks.'

  # Adding and removing ditto.
  def cmd_addmask(irc, line)
    rn, ud = get_data(irc)
    return unless ud
    m = ud['masks'] || (ud['masks'] = [])
    mask = (line && !line.empty?) ? line : irc.from.mask
    if m.include?(mask)
      irc.reply "The hostmask #{mask} is already in your list."
    else
      m << mask
      irc.reply "Hostmask #{mask} added to your list."
    end
  end
  help :addmask, "Adds your current hostmask (use 'hostmask' to see it) to your current list of known hostmasks. Please be careful, as anyone matching your current hostmask will be allowed to identify as you after this (unless you have secure mode on)."

  def cmd_delmask(irc, line)
    unless line and !line.empty?
      irc.reply "USAGE: delmask <number or mask>"
    end
    rn, ud = get_data(irc)
    return unless ud
    if (m = ud['masks'])
      begin
        i = Integer(line)
        if i >= 1 and i <= m.length
          mask = m.delete_at(i - 1)
          irc.reply "Deleted hostmask #{i}: #{mask}"
        else
          irc.reply "Hostmask number is out of range! You have #{m.length} hostmasks."
        end
      rescue ArgumentError
        if (mask = m.delete(line))
          irc.reply "Deleted hostmask: #{mask}"
        else
          irc.reply "No such mask in your list."
        end
      end
    else
      irc.reply "You have no hostmasks!"
    end
  end
  help :delmask, 'Deletes the given hostmask from your list of hostmasks.'

  # Make me or someone else operator.
  def chan_op(irc, chan, nick)
    if !caps(irc, 'op', 'owner').any?
      irc.reply "You don't have the 'op' capability for this channel; go away."
    elsif !chan.me.op?
      irc.reply "I don't appear to be operator on this channel, sorry."
    elsif nick
      if (nicks = nick.split).length == 1
        if (u = chan.users[IRC::Address.normalize(nicks[0])])
          if u.op?: irc.reply "Ehm, that person is already operator, dude."
          else u.op end
        else irc.reply "No such nick name." end
      else
        nicks.each { |n| u = chan.users[IRC::Address.normalize(n)] and !u.op? and u.op }
      end
    elsif (u = chan.users[irc.from.nnick])
      if u.op?: irc.reply "Already there, bro."
      else u.op end
    end
  end
  help :op, 'Gives you, or a given nick, operator status on the channel.'

  # Deop me or someone else.
  def chan_deop(irc, chan, nick)
    if !caps(irc, 'op', 'owner').any?
      irc.reply "You don't have the 'op' capability for this channel; go away."
    elsif !chan.me.op?
      irc.reply "I don't appear to be operator on this channel, sorry."
    elsif nick
      if (nicks = nick.split).length == 1
        if (u = chan.users[IRC::Address.normalize(nicks[0])])
          if !u.op?: irc.reply "That person is already a commoner, don't waste my time."
          else u.op(false) end
        else irc.reply "No such nick name." end
      else
        nicks.each { |n| u = chan.users[IRC::Address.normalize(n)] and u.op? and u.op(false) }
      end
    elsif (u = chan.users[irc.from.nnick])
      if !u.op?: irc.reply "Ok... done.  See?  No difference."
      else u.op(false) end
    end
  end
  help :deop, 'Removes operator status from you or the given nick.'

  # Display your channel caps.
  def chan_caps(irc, chan, line)
    cap = {}
    plugs = []
    cmds = []
    caps(irc) do |dir|
      old = cap
      cap = dir.reject { |k,v| !CapsList.include?(k) or !v }
      cap.merge! old
    end
    irc.reply "Channel capabilities: #{cap.keys.join(', ')}."
  end
  help :caps, 'Displays your current capabilities for this channel.'

  # Kicks a user.
  def chan_kick(irc, chan, line)
    n, r = line.split(' ', 2) if line
    if !caps(irc, 'op', 'owner').any?
      irc.reply "You're not allowed to do that."
    elsif !chan.me.op?
      irc.reply "I'm not operator. Can't do this."
    elsif !line or !n
      irc.reply "USAGE: kick <nick> [reason]"
    elsif !chan.users[IRC::Address.normalize(n)]
      irc.reply "No such nick, #{n}."
    else
      irc.server.cmd('KICK', chan.name, n, r || 'Chill')
    end
  end
  help :kick, 'Kicks a user from the channel.'

  # Kicks and bans a user.
  # TODO: Allow for ban-mask control.
  def chan_kban(irc, chan, line)
    usage = "USAGE: kban <nick> [timeout] [reason]"
    n, a1, a2 = line.split(' ', 3) if line
    if !caps(irc, 'op', 'owner').any?
      irc.reply "You're not allowed to do that."
    elsif !chan.me.op?
      irc.reply "I'm not operator. Can't do this."
    elsif !line or !n
      irc.reply usage
    elsif !(u = chan.users[IRC::Address.normalize(n)])
      irc.reply "No such nick, #{n}."
    else

      # Figure out arguments :-p.
      time = 0
      reason = 'Chill'
      if a1: begin
        time = Integer(a1)
        reason = a2
      rescue ArgumentError
        reason = a1
        if a2: begin
          time = Integer(a2)
        rescue ArgumentError
          irc.reply usage
        end end
      end end

      # Ban, then kick.
      ban_mask = "*!*@#{u.host}"
      irc.server.cmd('MODE', chan.name, '+b', ban_mask)
      irc.server.cmd('KICK', chan.name, n, reason)

      # Timeout to remove the ban, if needed.
      if time > 0: Thread.new do
        sleep(time)
        irc.server.cmd('MODE', chan.name, '-b', ban_mask)
      end end

    end
  end
  help :kban, "Kicks and bans a user from the channel. Type 'kban <nick> [time] [reason]' to ban the person for [time] seconds, with an optional reason. If [time] is not given, or given as 0, the ban is permanent."

  # Unbans a nick or mask.
  def chan_unban(irc, chan, mask)
    if !caps(irc, 'op', 'owner').any?
      irc.reply "You're not allowed to do that."
    elsif !chan.me.op?
      irc.reply "I'm not operator. Can't do it."
    elsif !mask or mask.empty?
      irc.reply 'USAGE: unban <mask or nick>'
    else

      # Figure out type of mask.
      if mask[0] == ?!
        mask = "*#{mask}"
      elsif mask[0] == ?@
        mask = "*!*#{mask}"
      end

      # See if we have, and unban.
      if !chan.bans.include? mask
        irc.reply "I don't see that mask in the channel ban list, but I'll try anyway, just for you."
      end
      irc.server.cmd('MODE', chan.name, '-b', mask)

    end
  end
  help :unban, 'Removes the given hostmask from the channel ban list.'

  # Server command hook so we can watch NICKs.
  def hook_command_serv(irc, handled, cmd, *args)
    return unless (s = @active_users[sn = irc.server.name])
    case cmd

    when 'NICK'
      return unless (u = s[nn = IRC::Address.normalize(on = irc.from.nick)])
      if $config['irc/track-nicks']
        new_nn = IRC::Address.normalize(args[0])
        return if new_nn == nn
        if u == true: s[new_nn] = nn
        else          s[new_nn] = (new_nn == u) ? true : u
        end
        $log.puts "User #{on} changed nick to #{args[0]} (tracking)."
        s.delete(nn)
      else
        $log.puts "User #{on} has left (nick name change)."
        irc.from.nick = new_nn
        lost_user(irc, s, nn, u)
        irc.from.nick = on
      end

    when 'QUIT'
      return unless (u = s[nn = irc.from.nnick])
      $log.puts "User #{nn} has left (quit)."
      lost_user(irc, s, nn, u)

    when 'KILL'
      return unless (u = s[nn = IRC::Address.normalize(args[0])])
      $log.puts "User #{nn} has left (kill)."
      lost_user(irc, s, nn, u)

    end
  end

  # Do stuff when we recognize a new user through JOIN or identify.
  def join_actions(irc, real_nick, bot_join = false)
    chan = irc.channel
    nick = irc.from.nick
    real_nick = nick unless real_nick
    serv_name = irc.server.name
    user_map = $config["servers/#{serv_name}/users/#{IRC::Address.normalize(real_nick)}"]
    chan_map = $config["servers/#{serv_name}/channels/#{chan.name}"]
    channel_actions(irc, user_map, chan_map, bot_join)
  end

  # Called to perform channel actions. Maps may be nil.
  def channel_actions(irc, user_map, chan_map, bot_join = false)

    # Operator or voice?
    cap = caps(irc, 'op', 'voice', 'greet')
    chan = irc.channel
    nick = irc.from.nick
    if chan_map
      if chan_map['enforce'] or chan_map['promote']
        if cap[0] and chan.me.op?
          chan.op(nick)
        end
        if cap[1] and chan.me.op?
          chan.voice(nick)
        end
      end
    end

    # Greeting?
    if !bot_join and cap[2] and user_map and (g = user_map['channels']) and (g = g[chan.name]) and (g = g['greeting'])
      chan.privmsg(g.gsub('%n', nick))
    end

  end

  # Perform actions on 'global' identification. Nick names must be normalized.
  def global_actions(irc, real_nick = nil, bot_join = false)

    # Grab some maps.
    server = irc.server
    server_name = server.name
    nick = irc.from.nnick
    real_nick = nick unless real_nick
    user_map = $config["servers/#{server_name}/users/#{real_nick}"]
    chan_map = $config["servers/#{server_name}/channels"]

    # Loop through channels, if applicable.
    old_chan = irc.channel
    server.channels.each do |chan_name, chan|
      if chan.users[nick]
        irc.channel = chan
        channel_actions(irc, user_map, chan_map ? chan_map[chan_name] : nil, bot_join)
      end
    end
    irc.channel = old_chan

  end

  # Called to initialize a new channel, after the user list and modes are fetched.
  # FIXME: Wrapper? hmm.
  def hook_init_chan(irc)

    irc.channel.users.each do |nn, user|
      next if @active_users.has_key?(user.nnick)
      @ident_queue << user unless @ident_queue.include?(user)
    end
    
    start_ident_thread(irc)

  end
  
  def start_ident_thread(irc)
    
    # This is the main IDENT thread.

    # it is started whenever we add user(s) to the @ident_queue (in hook_init_chan or
    # hook_command_chan).
    
    # Users in the @ident_queue are processed one at a time.
    
    # For each user, we send a WHOIS «nick».  This gives us the account name which is
    # currently using that nick (or says that the user has not logged in).  We then
    # check that the nick is actually registered to that account name by sending
    # NickServ INFO «nick».  The user is identified when the account names reported by
    # WHOIS and NickServ INFO match.
    
    # When we send a WHOIS / NickServ INFO, a thread is started to wait for the response.
    # The threads spin on a lock, waiting for the event handlers (hook_reply_serv or hook_notice_priv) to finish.
    
    # only one @ident_thread at a time please  
    return unless @ident_thread.nil?
    
    @ident_thread = Thread.new(irc) do |irc|
      begin

        # turn off notices until the ident thread is done
        irc.server.quiet_notices = true
        
        while @ident_queue.length > 0
          
          # don't start a new ident until the last one has finished.
          sleep(0.1) while not @ident_in_progress.nil?
          
          @ident_in_progress = @ident_queue.shift
          
          # skip if this nnick has been identified already.
          if @active_users.has_key?(@ident_in_progress.nnick)
            @ident_in_progress = nil
            next
          end
          
          # NickServ really does not like too many messages coming in. We have to be careful.
          sleep(1)
          
          # this call starts a thread that will eventually set @ident_in_progress = nil.
          auto_ident(irc,@ident_in_progress)
          
        end
      
        # wait for the last ident to finish before terminating this thread.
        sleep(1) until @ident_in_progress.nil?
        
      # errors need to be written on the log, since they will only crash this thread.
      rescue Exception => e
        $log.puts e.message
        $log.puts e.backtrace.join("\n")
      
      ensure
        @ident_thread = nil
        @ident_in_progress = nil
        irc.server.quiet_notices = false
      end
    end
  end

  # Auto-identify a joined user.
  # FIXME: Make an internal one for speed-up of bot-join.
  def auto_ident(irc, user, bot_join = false)
    
    # Only for un-indentified people.
    if ((au = @active_users[irc.server.name]) and au[@ident_in_progress.nnick])
      @ident_in_progress = nil
      return
    end
    
    # initialize locks
    @whois_lock = true
    @info_lock  = true
    
    # This variable maintains state while the server responds
    # to our WHOIS / NickServ INFO commands. This is necessary
    # because hook_reply_serv / hook_notice_priv are called just
    # once for each _line_ the server writes back.
    @whois[irc.server.name] = {:mask                       => nil,
                               :account_using_nick               => nil,
                               :is_identified_to_services  => false,
                               :account_that_owns_nick     => nil,
                               :bot_join                   => bot_join}
    
    
    # hook_reply_serv is called when the server responds to WHOIS
    irc.server.cmd('WHOIS', @ident_in_progress.nick)
    start_whois_thread(irc) # waits on @whois_lock
    
  end
  
  def start_whois_thread(irc)
    Thread.new(irc) do |irc|
      begin
        
        # Now we wait (up to a minute) for WHOIS.
        (60/(t = 0.1)).to_i.times do
            break unless @whois_lock
            sleep(t)
        end
        
        if @whois_lock # wait finished before @whois_lock was released.
          @ident_queue << @ident_in_progress
          @ident_in_progress = nil
          start_ident_thread(irc)
          Thread.exit
        end
        
        # if WHOIS tells us that the user is not logged in, we are done.
        unless @whois[irc.server.name][:is_identified] # user is identified to services
          $log.puts("[#{irc.server.name}] Unidentified user “#{@ident_in_progress.nick}”.")
          @ident_in_progress = nil
          Thread.exit
        end
        
        # hook_notice_priv is called when the server responds to NickServ INFO
        irc.server.cmd("PRIVMSG", "NickServ", "INFO #{@ident_in_progress.nick}")
        start_nickserv_info_thread(irc) # waits on @info_lock
        
      rescue Exception => e
        $log.puts e.message
        $log.puts e.backtrace.join("\n")
      end
    end
  end
 
  def start_nickserv_info_thread(irc)
    Thread.new(irc) do |irc|
      begin
        
        sn    = irc.server.name
        
        nick  = @ident_in_progress.nick
        nnick = @ident_in_progress.nnick
        
        # Now we wait (up to a minute) for NickServ to respond.
        (60/(t = 0.1)).to_i.times do
            break unless @info_lock
            sleep(t)
        end
        
        # wait finished before @info_lock was released.
        if @info_lock
          @ident_queue << @ident_in_progress
          @ident_in_progress = nil
          start_ident_thread(irc)
          Thread.exit
        end
        
        if @whois[sn][:account_that_owns_nick] == @whois[sn][:account_using_nick]
          
          # accounts match, so we log in the user.
          
          map = $config.ensure("servers/#{sn}/users/#{nnick}")
          if (users = $config["servers/#{sn}/users/#{nnick}"])
            
            # We need to fake-up an Address...
            old_from = irc.from
            irc.from = IRC::Address.new(@whois[:mask], irc.server)
            seen_user(irc, @active_users[sn], nnick)
            
            $log.puts "[#{sn}] Identified “#{nick}” aka #{@whois[sn][:account_using_nick]}."
            
            global_actions(irc, nil, @whois[:bot_join])
            irc.from = old_from
          end

        elsif @whois[sn][:account_that_owns_nick].nil?
          $log.puts("[#{sn}] Unregistered nick “#{nick}” in use by #{@whois[sn][:account_using_nick]}.")
        
        else
          $log.puts "[#{sn}] ¡“#{nick}” aka #{@whois[sn][:account_using_nick]} is using #{@whois[sn][:account_that_owns_nick]}'s nick!"
        
        end
      
      rescue Exception => e
        $log.puts e.message
        $log.puts e.backtrace.join("\n")
      ensure
        @ident_in_progress = nil
      end
    end
  end

  # Capture WHOIS output (for auto_ident).
  # This function is called once for each server reply
  # it populates the @whois variable, before unlocking the @whois_lock
  # allowing the whois_thread to run.
  def hook_reply_serv(irc, code, *data)
        
    return unless (whois = @whois[sn = irc.server.name])
    
    case code
    when 318,401 # ERR_NOSUCHNICK / ENDOFWHOIS
      @whois_lock = false
    
    when 311
      whois[:mask] = "#{data[0]}!#{data[1]}@#{data[2]}"

    # Ident info.
    when @whoisidentified_code[sn] # WHOISIDENTIFIED
      if data[-1] =~ /is signed on as account (.*)/
        whois[:is_identified] = true
        whois[:account_using_nick]  = IRC::Address.normalize($1) # record account name
      end
    end
    
  end
  
  
  # This function is called once for each line in the NickServ INFO response.
  # It checks that the account name from NickServ INFO matches the account name
  # from WHOIS and populates @whois with that data. It then releases @info_lock
  # allowing the NickServ INFO thread to run.
  def hook_notice_priv(irc, message)
        
    if message =~ /\*\*\*/ or message =~ /is not registered/
      @info_lock = false
    end
    
    sn = irc.server.name
    message = message.split("\x02")
    
    if irc.from.nnick == "nickserv" and message[0].index('Information on') == 0
      @whois[sn][:account_that_owns_nick] = IRC::Address.normalize(message[3])
    end
  end

  # Called to add a user to the list of currently known users. Normalized nick names must be used.
  def seen_user(irc, server_map, nick = nil, real_nick = nil)
    nick = irc.from.nnick unless nick
    if !real_nick or nick == real_nick
      server_map[nick] = true
      real_nick ||= nick
    else
      server_map[nick] = real_nick
      server_map[real_nick] = true
    end
    @user_watch_hooks.each { |m| m.call(true, irc, real_nick) }
  end

  # Called to erase a user from the list of currently known users.
  def lost_user(irc, server_map, nick = nil, user = nil)
    nick = irc.from.nnick unless nick
    user = server_map[nick] unless user
    real_nick = user == true ? nick : user
    @user_watch_hooks.each { |m| m.call(false, irc, real_nick) }
    server_map.delete(nick)
  end

  # Internal helper.
  def part_or_kick(irc, nick)
    return unless (s = @active_users[(serv = irc.server).name]) and (u = s[nick])
    serv.channels.each_value do |chan|
      return if chan.users.keys.include?(nick)
    end
    lost_user(irc, s, nick, u)
    $log.puts "User #{nick} has left."
  end

  # Channel command hook so we can watch JOIN, PART, KICK and QUITs.
  def hook_command_chan(irc, handled, cmd, *args)
    case cmd

    when 'JOIN'
      
      # JOINing puts us on top of the queue.
      @ident_queue.delete(irc.from)
      @ident_queue.unshift(irc.from)
      
      start_ident_thread(irc)
      
    when 'PART'
      part_or_kick(irc, irc.from.nnick)
    when 'KICK'
      part_or_kick(irc, IRC::Address.normalize(args[0]))

    end
  end


  # Check if a command can be executed.
  def command_check(irc, plugin_name, command_name)
    nplugin_name = "-#{plugin_name}"
    ncommand_name = "-#{command_name}"
    caps(irc) do |map|
      if (m = map['commands'])
        return if m.include? command_name
        if m.include? ncommand_name
          raise SecurityError.new("Error: You're not allowed to use the command '#{command_name}'.")
        end
      end
      if (m = map['plugins'])
        return if m.include? plugin_name
        if m.include? nplugin_name
          raise SecurityError.new("Error: You're not allowed to use commands from the plugin '#{plugin_name}'.")
        end
      end
    end
  end

  # Retrieve the given capability flag for the user.
  # We look in up to 5 places for the most local version:
  #  1. servers/<name>/users/<name>/channels/<name>/<cap>
  #  2. servers/<name>/users/<name>/<cap>
  #  3. servers/<name>/channels/<name>/defaults/<cap>
  #  4. servers/<name>/defaults/<cap>
  #  5. irc/defaults/<cap>
  #
  # For non-channel caps, only steps 2, 4 and 5 are performed. Pass 'false' as
  # the first argument after irc, to trigger this. Otherwise, if a block is given
  # arguments are disregarded and each level map is yielded to the block.
  #
  def caps(irc, *cap)

    # Prepare.
    if cap[0] == false
      skip_chan = true
      cap.shift
    else
      ship_chan = false
    end
    res = block_given? ? nil : Array.new(cap.length)

    # Walk to current server. This shouldn't fail.
    cn = irc.channel and cn = cn.name
    if (serv = $config["servers/#{sn = irc.server.name}"])

      # Look for user settings if we're identified.
      irc_user = irc.from
      nick = irc_user.nnick
      users = serv['users']
      if (s = @active_users[sn]) and (u = s[nick])
        nick = u unless u == true
      elsif users and (user = users[nick]) and
        user['auth'] == 'hostmask' and user['masks'].include_mask?(irc_user.mask)
        $log.puts "On-the-fly auth for user #{nick}."
        u = true
      end

      # So… if the above checked out…
      if u

        # This shouldn't fail, since we're known.
        if users and (user = users[nick])

          # Look for channel settings for this user, if we need them at all.
          if !skip_chan and cn and (chan = user['channels']) and (chan = chan[cn])
            if block_given?
              yield chan
            else
              cap.each_with_index { |e,i| res[i] = chan[e] if res[i].nil? }
            end
          end

          # Look for server settings for this user.
          if block_given?
            yield user
          else
            cap.each_with_index { |e,i| res[i] = user[e] if res[i].nil? }
          end
        end
      end

      # Now look for channel settings, if needed.
      if !skip_chan and cn and (chan = serv['channels']) and (chan = chan[cn]) and (chan = chan['defaults'])
        if block_given?
          yield chan
        else
          cap.each_with_index { |e,i| res[i] = chan[e] if res[i].nil? }
        end
      end

      # And server settings.
      if (c = serv['defaults'])
        if block_given?
          yield c
        else
          cap.each_with_index { |e,i| res[i] = c[e] if res[i].nil? }
        end
      end
    end

    # Finally, global settings.
    unless (c = $config["irc/defaults"]).nil?
      if block_given?
        yield c
      else
        cap.each_with_index { |e,i| res[i] = c[e] if res[i].nil? }
      end
    end
    (res.nil? or res.length > 1) ? res : res[0]

  end

end

