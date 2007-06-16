#
# TextMate related stuff.
#

require 'async'
require 'net/http'
require 'set'

class Textmate < PluginBase

  def phrase_to_keywords(phrase)
    phrase.gsub(/\b(\w+)s\b/, '\1').downcase.split(/\W/).to_set
  end

  def parse_toc(text)
    res = []
    text.grep(%r{<li>\s*([\d.]+)\s*<a href='(.*?)'>(.*?)</a>}) do |line|
      res << {
        :title    => "#{$1} #{$3}",
        :link     => "http://macromates.com/textmate/manual/#{$2}",
        :keywords => phrase_to_keywords($3)
      }
    end
    res
  end

  def cmd_doc(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: doc <search string or regex>'
    else
      Async.run(irc) do
        Net::HTTP.start('macromates.com') do |http|
          re = http.get('/textmate/manual/',  { 'User-Agent' => 'CyBrowser' })
          if re.code == '200'

            search_keywords = phrase_to_keywords(line)
            entries = parse_toc re.body
            matches = entries.find_all { |m| search_keywords.subset? m[:keywords] }
            if matches.empty?
              irc.reply 'No matches found.'
            else
              ranked = matches.map { |m| m.merge({ :rank => search_keywords.length.to_f / m[:keywords].length }) }
              hit = ranked.max { |a, b| a[:rank] <=> b[:rank] }
              irc.respond "\x02#{hit[:title]}\x0f #{hit[:link]}"
            end

          else
            irc.reply "Documentation site returned an error: #{re.code} #{re.message}"
          end
        end
      end
    end
  end
  help :doc, 'Searches the TextMate manual for the given string or regex.'

  def parse_faq(text)
    res = [ ]
    text.grep(%r{<a name=["'](.*?)["'][^>]*>.*?Keywords:(.*?)</span>}) do |line|
      res << {
        :link     => 'http://macromates.com/wiki/Main/FAQ#' + $1,
        :keywords => phrase_to_keywords($2)
      }
    end
    res
  end

  def cmd_faq(irc, line)
    if line.to_s.empty?
      irc.reply 'USAGE: faq <search keyword(s)>'
    else
      Async.run(irc) do
        Net::HTTP.start('macromates.com') do |http|
          re = http.get('/wiki/Main/FAQ',  { 'User-Agent' => 'CyBrowser' })
          if re.code == '200'

            search_keywords = phrase_to_keywords(line)
            entries = parse_faq re.body
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
    end
  end
  help :faq, 'Searches the TextMate FAQ for the given keyword(s).'

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

