require 'nokogiri'
require 'open-uri'
require 'openssl'
require 'pathname'

if ARGV.empty?
   $stderr.puts "usage: #{__FILE__} megido_name"
   exit 1
end

ENV["SSL_CERT_FILE"] = "./cacert.pem"

sections = 1.5.step(6.0, 0.5).to_a
sec_i = 0

item_orders = File.readlines("data/item_order.txt").map do |line|
   item = line.strip
   if item.empty?
      "DUMMY_SEPARATOR"
   else
      item
   end
end

doc = nil
URI.open(URI.encode("https://megido72material.swiki.jp/index.php?#{ARGV[0]}"), ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE) do |f|
   doc = Nokogiri::HTML.parse(f)
end

rows = []
star = "☆"
doc.xpath("//h2[contains(text(),'#{star}')]").each do |h2|
   table = h2.xpath("following-sibling::div/table").first

   item_counts = {}
   table.xpath("tbody/tr").each do |tr|
      cand = tr.xpath("td").to_a.last(3)

      text = if !cand[0].has_attribute?('rowspan')
                cand[0].text
             elsif !cand[1].has_attribute?('rowspan')
                cand[1].text
             else
                cand[2].text
             end

      item, count = text.split("×")
      count ||= 1
      count = count.to_i

      item_counts[item] ||= 0
      item_counts[item] += count
   end

   puts "[#{sections[sec_i]}]"
   item_orders.each do |item|
      next unless item_counts.has_key?(item)
      puts "#{item} = #{item_counts[item]}\n"
   end
   puts ""

   row = item_orders.map do |item|
      unless item_counts.has_key?(item)
         0
      else
         item_counts[item]
      end
   end.join("\t")
   rows.push(row)

   sec_i += 1
end

unless rows.empty?
   result = rows.reverse.join("\n")
   dir = Pathname.new("result")
   dir.mkpath
   file = dir / "#{ARGV[0]}.txt"
   file.write(result)
end

