#!/usr/bin/env ruby

require "optparse"
require "open-uri"
require "openssl"
require "pathname"
require "erb"

require "nokogiri"

def main(args)
  mode, name, options = parse_args(args)

  cache_dir = Pathname.new("cache") / mode.to_s

  order = Pathname.new("data/material_order.txt")
  formatter = Megido::MaterialFormatter.new(order)

  case mode
  when :megido
    extractor = Megido::MegidoGiftExtractor.new(name)

    cache_dir.mkpath if cache_dir && !cache_dir.directory?
    capture_page_cache = cache_dir / "#{name}-capture.html"
    material_page_cache = cache_dir / "#{name}-material.html"
    if options[:reload]
      capture_page_cache.delete if capture_page_cache.file?
      material_page_cache.delete if material_page_cache.file?
    end

    number = extractor.get_number(page_cache: capture_page_cache)
    gifts = extractor.get_gifts(page_cache: material_page_cache)

    text = formatter.format_megido_gifts(name, number, gifts)
  when :reiho
    extractor = Megido::ReihoRecipeExtractor.new(name)

    cache_dir.mkpath if cache_dir && !cache_dir.directory?
    page_cache = cache_dir / "reiho.html"
    if options[:reload]
      page_cache.delete if page_cache.file?
    end

    recipe = extractor.get_recipe(page_cache: page_cache)

    text = formatter.format_reiho_recipe(name, recipe)
  else
    raise "Unknown mode: #{mode}"
  end

  result_dir = Pathname.new("result") / mode.to_s
  result_dir.mkpath unless result_dir.directory?
  result_file = result_dir / "#{name}.txt"
  result_file.write(text)
end

def parse_args(args)
  options = {}
  opt_parser = OptionParser.new do |p|
    p.banner = "usage: #{File.basename($0)} [OPTIONS] MODE NAME
  Available modes: megido, reiho"
    p.on("-r", "--reload", "reload page html even if there are page caches")
  end
  opt_parser.parse!(args, into: options)

  mode = args.shift&.to_sym
  raise "No mode specified" unless mode
  name = args.shift
  raise "No name specified" unless name

  [mode, name, options]
end

module Megido
  # 攻略Wiki URL
  CAPTURE_WIKI_URL = "https://megido72wiki.com/index.php"
  # 素材Wiki URL
  MATERIAL_WIKI_URL = "https://megido72material.swiki.jp/index.php"

  module Fetching
    # ページのHTMLをパースして取得
    # @option [String] ページキャッシュファイル。指定した場合はここから読み込む
    def get_html(url, page_cache: nil)
      cache = Pathname.new(page_cache) if page_cache
      page = cache.read if cache&.file?
      page ||= fetch_page(url)
      cache&.write(page) unless cache&.file?
      parse_page(page)
    end
  end

  module Parsing
    # 素材Wikiのテーブルから素材の必要数を取得
    # @return [Hash<String, Integer>] 素材と必要数の対応表
    def count_table(table)
      counts = {}
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
      counts
    end
  end

  module Logging
    # ログを残す
    # @param [Symbol,String] level ログレベル。fatal, warn, info, log あたりが有効
    # @param [Class] klass 呼び出し元のクラス
    # @param [String] text ログの内容
    def log(level, klass, text)
      if @logger
        @logger.public_send(level, klass.name) { text }
      else
        $stderr.puts "[#{level.to_s.upcase}] #{klass.name}: #{text}"
      end
    end
  end

  # メギドへの贈り物抽出器
  class MegidoGiftExtractor
    include Fetching
    include Parsing

    NUMBER_REGEXP = /\A(.+?)-?(\d+)\z/
    STAR = "☆"
    LEVEL_REGEXP = /[\d.]+/

    def initialize(megido_name)
      @name = megido_name
      @capture_url = CAPTURE_WIKI_URL + "?" + ERB::Util.url_encode(megido_name)
      @material_url = MATERIAL_WIKI_URL + "?" + ERB::Util.url_encode(megido_name)
    end

    # 攻略WikiからメギドNoを取得する
    # @option [String] page_cache 攻略Wiki該当ページのキャッシュファイル名
    # @return [String] フォーマット変更済みのメギドNo
    # @example
    #   Megido::MegidoGiftExtractor.new("アスモデウス").get_number # => "祖-001"
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
    def get_gifts(page_cache: nil)
      html = get_html(@material_url, page_cache: page_cache)
      materials = {}
      # 星が含まれているものが進化度毎の素材一覧
      html.xpath("//h2[contains(text(),'#{STAR}')]").each do |h2|
        # 進化度を抽出
        level = h2.text.scan(LEVEL_REGEXP).last.to_f
        # 素材情報を抽出
        table = h2.xpath("following-sibling::div/table").first
        counts = count_table(table)
        materials[level] = counts
      end
      materials
    end
  end

  # 霊宝作成レシピ抽出器
  class ReihoRecipeExtractor
    include Fetching
    include Parsing

    REIHO_PAGE_URL = MATERIAL_WIKI_URL + "?霊宝レシピ"

    def initialize(reiho_name)
      @name = reiho_name
    end

    # レシピを取得
    # @option [String] page_cache 素材Wiki該当ページのキャッシュファイル名
    def get_recipe(page_cache: nil)
      html = get_html(REIHO_PAGE_URL, page_cache: page_cache)
      materials = {}
      h4 = html.xpath("//h4[contains(text(),'#{@name}')]").first
      table = h4.xpath("following-sibling::div/table")[1]
      count_table(table)
    end
  end

  # スプレッドシート用にフォーマット
  class MaterialFormatter
    include Logging

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

    def initialize(order, logger: nil)
      @order = File.readlines(order).map { |line| line.strip }
      @logger = logger
    end

    # メギド贈り物用にフォーマット
    # @param [String] name メギド名
    # @param [String] number メギドNo
    # @param [Hash<Numeric, Hash<String, Integer>>] materials 進化度、素材名で参照される素材数
    # @return [String] スプレッドシートに行毎にコピペする用の形式
    def format_megido_gifts(name, number, gifts)
      gifts = gifts.dup

      # 進化度が高い順で出力
      rows = EVOLUTION_LEVELS.keys.reverse.map do |level|
        row = [number, name, EVOLUTION_LEVELS[level]]
        counts = @order.map do |name|
          # 削除しながら取り出す
          gifts[level].delete(name) || 0
        end
        (row + counts).join("	")
      end

      # 空でない場合はアイテムの見落としがあるので警告を出す
      not_handled = gifts.values.map(&:keys).flatten.uniq
      unless not_handled.empty?
        log(:warn, self.class, "Not handled material: #{not_handled.join(", ")}")
      end

      rows.join("
")
    end

    # 霊宝レシピ用にフォーマット
    # @param [String] name 霊宝名
    # @param [Hash<String, Integer>] recipe 素材と必要数の対応表
    # @return [String] スプレッドシートに行毎にコピペする用の形式
    def format_reiho_recipe(name, recipe)
      recipe = recipe.dup

      row = [name]
      counts = @order.map do |name|
        # 削除しながら取り出す
        recipe.delete(name) || 0
      end
      row = (row + counts).join("	")

      # 空でない場合はアイテムの見落としがあるので警告を出す
      not_handled = recipe.keys
      unless not_handled.empty?
        log(:warn, self.class, "Not handled material: #{not_handled.join(", ")}")
      end

      row
    end
  end
end

# Webページを取得
# @return [String] バイナリ形式のページ内容
def fetch_page(url)
  # 文字化けを防ぐ
  # https://qiita.com/foloinfo/items/435f0409a6e33929ef3c
  URI.open(url, "r:binary", ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE).read
end

# Webページ内容をパース
# @return [Nokogiri::HTML] パース済みHTMLドキュメント
def parse_page(page)
  Nokogiri::HTML(page, nil, "utf-8")
end

if $0 == __FILE__
  main(ARGV)
end
