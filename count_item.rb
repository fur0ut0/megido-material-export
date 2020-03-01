#!/usr/bin/env ruby

require "optparse"
require "open-uri"
require "openssl"
require "pathname"

require "nokogiri"

def main(args)
  megido_name, options = parse_args(args)

  extractor = MegidoInfoExtractor.new(megido_name)
  options[:cache_dir].mkpath if options[:cache_dir] && options[:cache_dir].directory?
  number = extractor.get_number(page_cache: options[:capture_page_cache])
  materials = extractor.get_materials(page_cache: options[:material_page_cache])

  order = Pathname.new("data/material_order.txt")
  formatter = MaterialFormatter.new(order)
  text = formatter.format(megido_name, number, materials)

  dir = Pathname.new("result")
  dir.mkpath unless dir.directory?
  file = dir / "#{megido_name}.txt"
  file.write(text)
end

def parse_args(args)
  options = {}
  opt_parser = OptionParser.new do |p|
    p.banner = "usage: #{File.basename($0)} [OPTIONS] MEGIDO_NAME"
    p.on("-c DIR", "--cache_dir FILE", "specify directory to save/load page caches")
  end
  opt_parser.parse!(args, into: options)

  megido_name = args.pop
  raise "No megido name specified" unless megido_name

  if options[:cache_dir]
    options[:cache_dir] = Pathname.new(options[:cache_dir])
    options[:capture_page_cache] = options[:cache_dir] / "#{megido_name}-capture.html"
    options[:material_page_cache] = options[:cache_dir] / "#{megido_name}-material.html"
  end

  [megido_name, options]
end

class MegidoInfoExtractor
  CAPTURE_WIKI_URL = "https://megido72wiki.com/index.php"
  MATERIAL_WIKI_URL = "https://megido72material.swiki.jp/index.php"
  NUMBER_REGEXP = /\A(.+?)-?(\d+)\z/
  STAR = "☆"
  LEVEL_REGEXP = /[\d.]+/

  def initialize(megido_name)
    @name = megido_name
    @capture_url = CAPTURE_WIKI_URL + "?" + megido_name
    @material_url = MATERIAL_WIKI_URL + "?" + megido_name
  end

  # 攻略WikiからメギドNoを取得する
  # @option [String] page_cache 攻略Wiki該当ページのキャッシュファイル名
  # @return [String] フォーマット変更済みのメギドNo
  # @example
  #   MegidoInfoExtractor.new("アスモデウス").get_number # => "祖-001"
  def get_number(page_cache: nil)
    html = get_html(@capture_url, page_cache: page_cache)
    number = html.xpath("//div[@class='ie5'][2]/table/tbody/tr/td").first.text
    prefix, id = NUMBER_REGEXP.match(number).captures
    number = prefix + "-" + format("%03d", id.to_i)
    number += "R" if @name.include?("（")
    number
  end

  # 素材Wikiから素材数を取得する
  # @option [String] page_cache 素材Wiki該当ページのキャッシュファイル名
  # @return [Hash<Numeric, Hash<String, Integer>>] 進化度、素材名で参照される素材数
  def get_materials(page_cache: nil)
    html = get_html(@material_url, page_cache: page_cache)
    materials = {}
    # 星が含まれているものが進化度毎の素材一覧
    html.xpath("//h2[contains(text(),'#{STAR}')]").each do |h2|
      counts = {}
      # 進化度を抽出
      level = h2.text.scan(LEVEL_REGEXP).last.to_f
      # 素材情報を抽出
      table = h2.xpath("following-sibling::div/table").first
      table.xpath("tbody/tr").each do |tr|
        # 合成専用素材は合成後のものをカウント
        cand = tr.xpath("td").to_a.last(3)
        text = if !cand[0].has_attribute?("rowspan")
            cand[0].text
          elsif !cand[1].has_attribute?("rowspan")
            cand[1].text
          else
            cand[2].text
          end

        # 名称と必要数を取得
        name, count = text.split("×")
        count = count&.to_i || 1

        counts[name] ||= 0
        counts[name] += count
      end
      materials[level] = counts
    end
    materials
  end

  private

  def get_html(url, page_cache: nil)
    cache = Pathname.new(page_cache) if page_cache
    page = cache.read if cache&.file?
    page ||= fetch_page(url)
    cache&.write(page) unless cache&.file?
    parse_page(page)
  end
end

class MaterialFormatter
  EVOLUTION_LEVELS = {
    1.5 => "★☆",
    2.0 => "★★",
    2.5 => "★★☆",
    3.0 => "★★★",
    3.5 => "★★★☆",
    4.0 => "★★★★",
    4.5 => "★★★★☆",
    5.0 => "★★★★★",
    5.5 => "★★★★★☆",
    6.0 => "★★★★★★",
  }

  def initialize(order)
    @order = File.readlines(order).map { |line| line.strip }
  end

  # 素材Wikiから素材数を取得する
  # @param [Hash<Numeric, Hash<String, Integer>>] materials 進化度、素材名で参照される素材数
  # @return [String] スプレッドシートに行毎にコピペする用の形式
  def format(name, number, materials)
    # 進化度が高い順で出力
    EVOLUTION_LEVELS.keys.reverse.map do |level|
      row = [number, name, EVOLUTION_LEVELS[level]]
      counts = @order.map do |name|
        materials[level][name] || 0
      end
      (row + counts).join("	")
    end.join("
")
  end
end

# Webページを取得
# @return [String] バイナリ形式のページ内容
def fetch_page(url)
  # 文字化けを防ぐ
  # https://qiita.com/foloinfo/items/435f0409a6e33929ef3c
  open(URI.encode(url), "r:binary", ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE).read
end

# Webページ内容をパース
# @return [Nokogiri::HTML] パース済みHTMLドキュメント
def parse_page(page)
  Nokogiri::HTML(page, nil, "utf-8")
end

if $0 == __FILE__
  main(ARGV)
end
