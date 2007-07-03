#
# Scribe plugin for CyBot, which passes around notes.
#

class Scribe < PluginBase

  def initialize(*args)
    @brief_help = 'Passes notes between people.'
    @notes = {}
    super(*args)
    @user_watch = method(:user_watch)
    $user.user_watch_hooks << @user_watch
  end

  def unregister
    $user.user_watch_hooks.delete @user_watch
    @user_watch = nil
  end

  def user_watch(seen_or_lost, irc, user_nick)
    if seen_or_lost
      if (n = @notes[sn = irc.server.name]) and (un = n[user_nick]) and !un.empty?
        count = 0
        un.each do |n|
          if !n[3]
            n[3] = true
            count += 1
          end
        end
        if count > 0
          notes = "note#{'s' if un.length > 1}"
          them  = un.length > 1 ? 'them' : 'it'
          irc.from.notice("You have #{un.length} unread #{notes} (#{count} of which I haven't told you about before). Use the 'notes' command to list #{them}.")
        end
      end
    end
  end

  # Load/save database.
  def load
    begin
      Dir[file_name('*.notes')].each do |n|
        $log.puts "Note file: #{n}"
        bn = File.basename(n)
        i = bn.rindex ?.
        @notes[bn[0...i]] = YAML.load_file(n)
      end
    rescue Exception => e
      $log.puts e.message
      $log.puts e.backtrace.join("\n")
    end
  end
  def save
    begin
      @notes.each do |k,v|
        open_file("#{k}.notes", 'w') do |f|
          f.puts "# CyBot scribe plugin: Notes for server '#{k}'"
          YAML.dump(v, f)
          f.puts ''
        end
      end
    rescue Exception => e
      $log.puts e.message
      $log.puts e.backtrace.join("\n")
    end
  end

  # Send a new note or read your next note.
  # Usages:
  # note              Read the next unread note for you.
  # note <num>        Read note number <num>.
  # note <to> <text>  Write a new note to someone.
  #
  def cmd_note(irc, line)
    u = $user.get_nick(irc) or return
    nu = IRC::Address.normalize(u)
    n = @notes[sn = irc.server.name] || (@notes[sn] = {})
    now = Time.now.to_i
    if !line or line.empty?
      if (e = n[nu]) and !e.empty?
        from, date, txt = e.shift
        n.delete(nu) if e.empty?
        irc.reply "From #{from}, sent #{seconds_to_s(now - date, irc)} ago: #{txt}"
      else
        irc.reply "You have no unread notes."
      end
    else
      to, txt = line.split(' ', 2)
      if txt
        if (t = $user.get_data(to, sn))
          nto = IRC::Address.normalize(to)
          nl = n[nto] || (n[nto] = [])
          if (announced = $user.get_nick(to, sn))
            as = (nn = irc.from.nick) == u ? '' : " (as #{nn.capitalize})"
            irc.server.notice(to, "#{u.capitalize}#{as} has sent you a note. Use 'notes' to list your unread notes.")
          end
          nl << [u, now, txt, announced ? true : false]
          irc.reply "Ok, note to #{to} added."
        else
          irc.reply "No such user, #{to}."
        end
      else
        if !(e = n[nu]) or e.empty?
          irc.reply "You have no unread notes."
        else
          begin
            i = Integer(to)
            if i >= 1 and i <= e.length
              from, date, txt = e[i - 1]
              irc.reply "Note #{i} from #{from}, sent #{seconds_to_s(now - date, irc)} ago: #{txt}"
            else
              notes = "note#{'s' if e.length > 1}"
              irc.reply "Note number out of range. You have #{e.length} unread #{notes}."
            end
          rescue ArgumentError
            irc.reply "USAGE: note <number>"
          end
        end
      end
    end
  end
  help :note, "Use 'note <nick> <message>' to send a note, or 'note' to read and remove your next available note.  You can also type 'note <n>' to read (wihtout removing) note number <n>.  Use the 'notes' command to get a list."

  # List unread notes.
  def cmd_notes(irc, line)
    u = $user.get_nick(irc) or return
    if (s = @notes[irc.server.name]) and (s = s[IRC::Address.normalize(u)]) and !s.empty?
      i = 0
      notes = "note#{'s' if s.length > 1}"
      irc.reply "You have the following #{notes}: #{s.map do |e|
        i += 1
        "[#{i}] #{e[0]} (#{seconds_to_s(Time.now.to_i - e[1], irc)} ago)"
      end.join(', ')}"
    else
      irc.reply "You have no unread notes."
    end
  end
  help :notes, 'Displays a list of your currently unread notes.'

end

