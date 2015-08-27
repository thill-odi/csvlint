require 'uri'
require 'zipfile'
require 'data_uri/open_uri'

class PackageController < ApplicationController
  before_filter :preprocess, :only => :create

  # preprocess performs necessary formatting of appended or hyperlinked files on the CSVlint frontend

  before_filter(:only => [:show]) { alternate_formats [:json] }

  def create
    urls = params[:urls].presence

    if !params[:files].blank?
      files = params[:files].map! do |file|
        f = File.open("/tmp/#{file}")
        stored_csv = Mongoid::GridFs.put(f)
        {
          :csv_id => stored_csv.id,
          :filename => file.split("/").last
        }
      end
    end

    redirect_to root_path and return if urls.blank? && files.nil?

    if params[:format] == "json"
      @package = Package.create
      @package.delay.create_package(urls || files, @schema_url, @schema)
    else
      package = Package.create
      package.create_package(urls || files, @schema_url, @schema)

      if package.validations.count == 1
        redirect_to validation_path(package.validations.first)
      else
        redirect_to package_path(package)
      end
    end
  end

  def show
    @package = Package.find( params[:id] )

    if @package.validations.count == 1 && params[:format] != "json"
      redirect_to validation_path(@package.validations.first)
    end

    @dataset = Marshal.load(@package.dataset) rescue nil
    @validations = @package.validations
  end

  private

    def preprocess
      remove_blanks!
      # pass files to function and return data as ActionDispatch object
      #params[:schema_file] = read_files(params[:schema_data]).first unless params[:schema_data].blank?
      params[:files] = read_files(params[:files_data]) unless params[:files_data].blank?
      redirect_to root_path and return unless urls_valid? || params[:files].presence
      load_schema
      Zipfile.check!(params)
    end

    def urls_valid?
      return false if params[:urls].blank?
      params[:urls].each do |url|
        return false if url.blank?
        # Check it's valid
        begin
          url = URI.parse(url)
          return false unless ['http', 'https'].include?(url.scheme)
        rescue URI::InvalidURIError
          return false
        end
      end
      return true
    end

    def remove_blanks!
      params[:urls].reject! { |url| url.blank? } unless params[:urls].blank?
      params[:files].reject! { |data| data.blank? } unless params[:files].blank?
    end

    def load_schema
      # Check that schema checkbox is ticked
      return unless params[:schema] == "1"

      # Load schema
      if params[:schema_url].presence
        @schema = Csvlint::Schema.load_from_json_table(params[:schema_url])
        @schema_url = params[:schema_url]
      elsif params[:schema_data] || params[:schema_file]
        if params[:schema_data]
          data = read_data_url(params[:schema_data])[:body]
        else
          data = params[:schema_file].tempfile.read
        end

        begin
          json = JSON.parse(data)
          @schema = Csvlint::Schema.from_json_table( nil, json )
        rescue JSON::ParserError
          # catch JSON parse error
          # this rescue requires further work, currently in place to catch malformed or bad json uploaded schemas
          @schema = Csvlint::Schema.new(nil, [], "malformed", "malformed")
        end
      end

      # Get schema URL from parameters
      @schema_url = params[:schema_url]
    end

    def check_for_package
      sources = params[:urls].presence || params[:files].presence
      Package.create_package( sources, params[:schema_url], @schema )
    end

    def read_data_url(data)
      file_array = data.split(";", 2)
      uri = URI::Data.new(file_array[1])
      {
        filename: file_array[0],
        body: open(uri).read
      }
    end

    def read_files(data)
      files = []
      data = [data] if data.class == String
      # converts the base64 schema to an array for parsing below
      data.each do |data|
        file = read_data_url(data)
        filename = (File.basename(file[:filename]) + Time.now.to_i.to_s).parameterize
        tempfile = File.new(File.join('/', 'tmp', filename), "w+")
        tempfile.binmode
        tempfile.write(file[:body])
        tempfile.rewind
        files << File.basename(tempfile.path)
      end
      files
    end

end
