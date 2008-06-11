#
# TextMate related stuff.
#

require 'net/http'
require 'set'

# ===============================
# = To facilitate local testing =
# ===============================

require 'async' unless $0 == __FILE__

class Async
  def Async.run(irc)
    yield
  end
end if $0 == __FILE__

class PluginBase
  def PluginBase.help(cmd, text)
    # STDERR << "Help registered for #{cmd}: #{text}.\n"
  end
end if $0 == __FILE__

# ===============================

module TMHelper
  module_function
  
  def phrase_to_keywords(phrase)
    phrase.gsub(/\b(\w+)s\b/, '\1').downcase.split(/\W/).to_set
  end

  def call_with_body(irc, url)
    return unless url =~ %r{http://([^/]+)(.+)}
    host, path = $1, $2

    Async.run(irc) do
      Net::HTTP.start(host) do |http|
        re = http.get(path,  { 'User-Agent' => 'CyBrowser/1.1 (IRC bot: http://wiki.macromates.com/Cybot/)' })
        if re.code == '200'
          yield re.body
        else
          irc.reply "#{re.code} #{re.message} for #{url}"
        end
      end
    end
  end
end

class Textmate < PluginBase

  def parse_toc(text)
    res = []
    text.grep(%r{<li>\s*([\d.]+)\s*<a href=['"](.*?)['"]>(.*?)</a>}) do |line|
      section = $1
      url = $2
      title = $3.gsub(%r{</?\w+>}, '')
      res << {
        :title    => "#{section} #{title}",
        :link     => "http://manual.macromates.com/en/#{url}",
        :keywords => TMHelper.phrase_to_keywords(title)
      }
    end
    res
  end

  def cmd_doc(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: doc <search string or regex>'
    else
      TMHelper.call_with_body(irc, 'http://manual.macromates.com/en/') do |body|
        search_keywords = TMHelper.phrase_to_keywords(line)
        entries = parse_toc body
        matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
        if matches.empty?
          irc.reply 'No matches found.'
        else
          ranked = matches.map { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
          hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
          irc.respond "\x02#{hit[:title]}\x0f #{hit[:link]}"
        end
      end
    end
  end
  help :doc, 'Searches the TextMate manual for the given string or regex.'

  def parse_faq(text)
    res = [ ]
    text.grep(%r{<a name=["'](.*?)["'][^>]*>.*?Keywords:(.*?)</span>}) do |line|
      res << {
        :link     => 'http://wiki.macromates.com/Main/FAQ#' + $1,
        :keywords => TMHelper.phrase_to_keywords($2)
      }
    end
    res
  end

  def cmd_faq(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: faq <search keyword(s)>'
    else
      TMHelper.call_with_body(irc, 'http://wiki.macromates.com/Main/FAQ') do |body|
        search_keywords = TMHelper.phrase_to_keywords(line)
        entries = parse_faq body
        matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
        if matches.empty?
          irc.reply 'No matches found.'
        else
          ranked = matches.collect { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
          hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
          irc.respond hit[:link]
        end
      end
    end
  end
  help :faq, 'Searches the TextMate FAQ for the given keyword(s).'

  def cmd_howto(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: howto <search keyword(s)>'
    else
      TMHelper.call_with_body(irc, 'http://wiki.macromates.com/Main/HowTo/') do |body|
        wiki_host  = 'wiki.macromates.com'
        wiki_group = 'HowTo'

        toc = body.scan(%r{<a .*\bhref=['"](http://#{wiki_host}/#{wiki_group}/(?!HomePage|RecentChanges).+)['"][^>]*>(.*?)</a>})
        entries = toc.map do |e|
          words = e[1].gsub(/([A-Z]+)([A-Z][a-z])/,'\1 \2').gsub(/([a-z\d])([A-Z])/,'\1 \2')
          { :link     => e[0],
            :keywords => TMHelper.phrase_to_keywords(words)
          }
        end

        search_keywords = TMHelper.phrase_to_keywords(line)
        matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
        if matches.empty?
          irc.reply 'No matches found.'
        else
          ranked = matches.collect { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
          hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
          irc.respond hit[:link]
        end
      end
    end
  end
  help :howto, 'Searches http://wiki.macromates.com/Main/HowTo/ for the given keyword(s).'

  def cmd_ts(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: ts <search keyword(s)>'
    else
      TMHelper.call_with_body(irc, 'http://wiki.macromates.com/Troubleshooting/HomePage/') do |body|
        wiki_host  = 'wiki.macromates.com'
        wiki_group = 'Troubleshooting'

        toc = body.scan(%r{<a .*\bhref=['"](http://#{wiki_host}/#{wiki_group}/(?!HomePage|RecentChanges).+)['"][^>]*>(.*?)</a>})
        entries = toc.map do |e|
          words = e[1].gsub(/([A-Z]+)([A-Z][a-z])/,'\1 \2').gsub(/([a-z\d])([A-Z])/,'\1 \2')
          { :link     => e[0],
            :keywords => TMHelper.phrase_to_keywords(words)
          }
        end

        search_keywords = TMHelper.phrase_to_keywords(line)
        matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
        if matches.empty?
          irc.reply 'No matches found.'
        else
          ranked = matches.collect { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
          hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
          irc.respond hit[:link]
        end
      end
    end
  end
  help :ts, 'Searches http://wiki.macromates.com/Troubleshooting/HomePage/ for the given keyword(s).'

  def cmd_calc(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: calc <expression>. The expression must be in the bc language.'
    else
      Async.run(irc) do
        result = nil
        IO.popen('bc -l 2>&1', 'r+') do |f|
          f.puts line
          result = f.gets.strip
        end
        irc.reply result
      end
    end
  end
  help :calc, "Calculates the expression given and returns the answer. The expression must be in the bc language."

end

if $0 == __FILE__
  class IRC
    class << self
      def reply(msg)
        STDERR << "→ " << msg << "\n"
      end
      alias respond reply
    end
  end

  tm  = Textmate.new

  tm.cmd_calc(IRC, '4 + 3')
  tm.cmd_doc(IRC, 'language grammar')
  tm.cmd_faq(IRC, 'remote')
  tm.cmd_howto(IRC, 'tidy')
  tm.cmd_ts(IRC, '101')
end
