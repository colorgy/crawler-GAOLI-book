require 'crawler_rocks'
require 'iconv'
require 'pry'
require 'book_toolkit'

require 'thread'
require 'thwait'
require 'parallel'

class GaoliBookCrawler
  include CrawlerRocks::DSL

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @search_url = "http://gau-lih.ge-light.com.tw/tier/front/bin/advsearch.phtml"
    @detail_url = "http://gau-lih.ge-light.com.tw/tier/front/bin/ptdetail.phtml"
    @ic = Iconv.new("utf-8//translit//IGNORE","big5")
    @mutex = Mutex.new
  end

  def books
    @books = []
    @threads = []
    @detail_threads = []

    r = RestClient.post @search_url, {
      "Sch_field1" => nil,
      "Sch_txt1" => nil,
      "Search" => CGI.escape("搜　　尋".encode('big5')),
    }

    @doc = Nokogiri::HTML(@ic.iconv r)
    page_num = 0
    @doc.css('form[name="AddCart"] td[align="left"][width="80%"]').text.match(/總共 : (?<b_n>\d+)/)  do |m|
      page_num = m[:b_n].to_i / 25 + 1
    end

    # a lot simpler pagination
    page_num.times do |i|
      puts i

      # parse_page
      @doc.css('.pt-tblist-tb tr:not(:first-child)').each_with_index do |row, row_i|
      # rows = @doc.css('.pt-tblist-tb tr:not(:first-child)')
      # Parallel.each_with_index(rows) do |row, index|
        sleep(1) until (
          @detail_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
          @detail_threads.count < (ENV['MAX_THREADS'] || 30)
        )
        @detail_threads << Thread.new do
          datas = row.css('td')

          internal_code = datas[2] && datas[2].text.strip
          url = "#{@detail_url}?Part=#{internal_code}"

          isbn = datas[8] && datas[8].text.strip
          isbn = nil if isbn.empty?
          invalid_isbn = nil
          begin
            isbn = BookToolkit.to_isbn13(isbn)
          rescue Exception => e
            invalid_isbn = isbn
            isbn = nil
          end

          # publisher, cover, 版次
          r = RestClient.get(url)
          doc = Nokogiri::HTML(@ic.iconv r)

          external_image_url = doc.css('img').map{|img| img[:src]}.find{|src| src.include?(internal_code)}
          if external_image_url.nil?
            if @tired
              @tired = false
            else
              @tired = true
              sleep 2
              redo
            end
          end

          pairs = []
          doc.css('.ptdet-def-table tr').each{|tr| pairs.concat tr.text.strip.split(/\n\t\t  \n\t\t  \n\t\t    \n\t\t/) }
          publisher = nil; edition = nil;
          pairs.map {|pp| pp.gsub(/\s+/, ' ').strip }.each do |attribute|
            attribute.match(/發行公司 : (.+)/) {|m| publisher ||= m[1]}
            attribute.match(/版次 : (.+)/) {|m| edition ||= m[1]}
          end


          book = {
            category: datas[1] && datas[1].text.strip,
            name: datas[3] && datas[3].text.strip.gsub(/\w+/, &:capitalize),
            author: datas[4] && datas[4].text.strip.gsub(/\w+/, &:capitalize),
            original_price: datas[6] && datas[6].text.gsub(/[^\d]/, '').to_i,
            internal_code: internal_code,
            url: url,
            isbn: isbn,
            invalid_isbn: invalid_isbn,
            external_image_url: external_image_url,
            publisher: publisher,
            edition: edition,
            known_supplier: 'gaoli'
          }
          @after_each_proc.call(book: book) if @after_each_proc
          @books << book
          # print "|"
        end # end detail thread
      end # end each row

      ThreadsWait.all_waits(*@detail_threads)
      puts

      r = RestClient.post @search_url, get_view_state.merge({"GoTo" => 'Next'})
      @doc = Nokogiri::HTML(@ic.iconv r)
    end

    @books
  end
end

# cc = GaoliBookCrawler.new
# File.write('gaoli_books.json', JSON.pretty_generate(cc.books))
