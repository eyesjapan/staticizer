require 'net/http'
require 'uri'

require 'dotenv'
require 'ruby-wpdb'
require 'aws-sdk'
require 'nokogiri'

require './util' # remove_query, remove_fragment, convert_site_url, calc_s3object_key


Dotenv.load

if ENV['WP_CONFIG_PATH'] != ""
  WPDB.from_config(ENV['WP_CONFIG_PATH'])
else
  WPDB.init("mysql2://#{ENV['DATABASE_USER']}:#{ENV['DATABASE_PASSWORD']}@#{ENV['DATABASE_HOST']}/#{ENV['DATABASE_NAME']}")
end

source_site_url = WPDB::Option.get_option('siteurl')
target_site_url = ENV['TARGET_SITE_URL']


uncrawled_urls = [source_site_url + '/']
crawled_urls = {}
s3objects = []


while uncrawled_urls.length > 0 do
  crawling_url = uncrawled_urls.shift
  crawled_urls[crawling_url] = true

  puts crawling_url

  response = Net::HTTP.get_response(URI.parse(crawling_url))

  if response['content-type'].start_with?('text/html')
    nokogiried = Nokogiri::HTML(response.body)

    ahref_urls      = nokogiried.xpath("//a     [starts-with(@href, '#{source_site_url}')]                   /@href").map{ |attr| attr.value }
    javascript_urls = nokogiried.xpath("//script[starts-with(@src,  '#{source_site_url}')]                   /@src") .map{ |attr| attr.value }
    stylesheet_urls = nokogiried.xpath("//link  [starts-with(@href, '#{source_site_url}')][@rel='stylesheet']/@href").map{ |attr| attr.value }
    image_urls      = nokogiried.xpath("//img   [starts-with(@src,  '#{source_site_url}')]                   /@src") .map{ |attr| attr.value }

    new_uncrawled_urls = (ahref_urls + javascript_urls + stylesheet_urls + image_urls).map{ |url| remove_fragment(url) }.reject{ |url| crawled_urls[url] }

    uncrawled_urls.concat(new_uncrawled_urls).uniq!

    nokogiried.xpath("//a[starts-with(@href, '#{source_site_url}')]/@href").each do |attr|
      attr.value = remove_query(convert_site_url(source_site_url, target_site_url, attr.value))
    end

    nokogiried.xpath("//script[starts-with(@src, '#{source_site_url}')]/@src").each do |attr|
      attr.value = remove_query(convert_site_url(source_site_url, target_site_url, attr.value))
    end

    nokogiried.xpath("//link[@rel='stylesheet'][starts-with(@href, '#{source_site_url}')]/@href").each do |attr|
      attr.value = remove_query(convert_site_url(source_site_url, target_site_url, attr.value))
    end

    nokogiried.xpath("//img[starts-with(@src, '#{source_site_url}')]/@src").each do |attr|
      attr.value = remove_query(convert_site_url(source_site_url, target_site_url, attr.value))
    end

    s3objects << { key: calc_s3object_key(source_site_url, remove_query(crawling_url)), body: nokogiried.to_html }
  else
    s3objects << { key: calc_s3object_key(source_site_url, remove_query(crawling_url)), body: response.body }
  end
end


s3 = Aws::S3::Resource.new
bucket = s3.bucket(ENV['AWS_S3_BUCKET'])

s3objects.each do |s3object|
  if s3object[:key] == ""
    bucket.object("index.html").put(body: s3object[:body])
  else
    bucket.object(s3object[:key]).put(body: s3object[:body])
  end
end