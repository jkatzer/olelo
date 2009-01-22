#!/usr/bin/env ruby
require "rubygems"
gem "mojombo-grit"

require "sinatra/base"
require "grit"
require "redcloth"

class String
  def titleize
    self.gsub(/([A-Z]+)([A-Z][a-z])/,'\1 \2').gsub(/([a-z\d])([A-Z])/,'\1 \2')
  end
end

module GitWiki
  class << self
    attr_accessor :homepage, :extension, :repository
  end

  def self.new(repository, extension, homepage)
    self.homepage   = homepage
    self.extension  = extension
    self.repository = Grit::Repo.new(repository)

    App
  end

  class PageNotFound < Sinatra::NotFound
    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  class Page
    def self.find_all
      return [] if repository.tree.contents.empty?
      repository.tree.contents.collect { |blob| new(blob) }
    end

    def self.find(name)
      page_blob = find_blob(name)
      raise PageNotFound.new(name) unless page_blob
      new(page_blob)
    end

    def self.find_or_create(name)
      find(name)
    rescue PageNotFound
      new(create_blob_for(name))
    end

    def self.css_class_for(name)
      find(name)
      "exists"
    rescue PageNotFound
      "unknown"
    end

    def self.repository
      GitWiki.repository || raise
    end

    def self.extension
      GitWiki.extension || raise
    end

    def self.find_blob(page_name)
      repository.tree/(page_name + extension)
    end
    private_class_method :find_blob

    def self.create_blob_for(page_name)
      Grit::Blob.create(repository, {
        :name => page_name + extension,
        :data => ""
      })
    end
    private_class_method :create_blob_for

    def initialize(blob)
      @blob = blob
    end

    def to_html
      linked = auto_link(wiki_link(content))
      RedCloth.new(linked).to_html
    end

    def to_s
      name
    end

    def new?
      @blob.id.nil?
    end

    def name
      @blob.name.gsub(/#{File.extname(@blob.name)}$/, '')
    end

    def content
      @blob.data
    end

    def update_content(new_content)
      return if new_content == content
      File.open(file_name, "w") { |f| f << new_content }
      add_to_index_and_commit!
    end

    private
      def add_to_index_and_commit!
        Dir.chdir(self.class.repository.working_dir) {
          self.class.repository.add(@blob.name)
        }
        self.class.repository.commit_index(commit_message)
      end

      def file_name
        File.join(self.class.repository.working_dir, name + self.class.extension)
      end

      def commit_message
        new? ? "Created #{name}" : "Updated #{name}"
      end

      def auto_link(str)
        str.gsub(/<((https?|ftp|irc):[^'">\s]+)>/xi, %Q{<a href="\\1">\\1</a>})
      end

      def wiki_link(str)
        str.gsub(/([A-Z][a-z]+[A-Z][A-Za-z0-9]+)/) { |page|
          %Q{<a class="#{self.class.css_class_for(page)}"} +
            %Q{href="/#{page}">#{page.titleize}</a>}
        }
      end
  end

  class App < Sinatra::Base
    set :app_file, __FILE__
    set :haml, { :format        => :html5,
                 :attr_wrapper  => '"'     }
    enable :static
    use_in_file_templates!

    error PageNotFound do
      page = request.env["sinatra.error"].name
      redirect "/#{page}/edit"
    end

    before do
      content_type "text/html", :charset => "utf-8"
    end

    get "/" do
      redirect "/" + GitWiki.homepage
    end

    get "/_stylesheet.css" do
      content_type "text/css", :charset => "utf-8"
      sass :stylesheet
    end

    get "/_list" do
      @pages = Page.find_all
      haml :list
    end

    get "/:page" do
      @page = Page.find(params[:page])
      haml :show
    end

    get "/e/:page" do
      @page = Page.find_or_create(params[:page])
      haml :edit
    end

    post "/e/:page" do
      @page = Page.find_or_create(params[:page])
      @page.update_content(params[:body])
      redirect "/#{@page}"
    end

    private
      def title(title=nil)
        @title = title.to_s unless title.nil?
        @title
      end

      def list_item(page)
        %Q{<a class="page_name" href="/#{page}">#{page.name.titleize}</a>}
      end
  end
end

__END__
@@ layout
!!!
%html
  %head
    %title= title
    %link{:rel => 'stylesheet', :href => '/_stylesheet.css', :type => 'text/css'}
    %script{:src => '/jquery-1.2.3.min.js', :type => 'text/javascript'}
    %script{:src => '/jquery.hotkeys.js', :type => 'text/javascript'}
    %script{:src => '/to-title-case.js', :type => 'text/javascript'}
    :javascript
      $(document).ready(function() {
        $.hotkeys.add('Ctrl+h', function(){document.location = '/#{GitWiki.homepage}'})
        $.hotkeys.add('Ctrl+l', function(){document.location = '/_list'})

        /* title-case-ification */
        document.title = document.title.toTitleCase();
        $('h1:first').text($('h1:first').text().toTitleCase());
        $('a').each(function(i) {
          var e = $(this)
          e.text(e.text().toTitleCase());
        })
      })
  %body
    #content= yield

@@ show
- title @page.name.titleize
:javascript
  $(document).ready(function() {
    $.hotkeys.add('Ctrl+e', function(){document.location = '/e/#{@page}'})
  })
%h1#page_title= title
#page_content
  ~"#{@page.to_html}"

@@ edit
- title "Editing #{@page.name.titleize}"
%h1= title
%form{:method => 'POST', :action => "/e/#{@page}"}
  %p
    %textarea{:name => 'body'}= @page.content
  %p
    %input.submit{:type => :submit, :value => 'Save as the newest version'}
    or
    %a.cancel{:href=>"/#{@page}"} cancel

@@ list
- title "Listing pages"
%h1#page_title All pages
- if @pages.empty?
  %p No pages found.
- else
  %ul#pages_list
    - @pages.each_with_index do |page, index|
      - if (index % 2) == 0
        %li.odd=  list_item(page)
      - else
        %li.even= list_item(page)

@@ stylesheet
body
  :font
    family: "Lucida Grande", Verdana, Arial, Bitstream Vera Sans, Helvetica, sans-serif
    size: 14px
    color: black
  line-height: 160%
  background-color: white
  margin: 0 10px
  padding: 0
h1#page_title
  font-size: xx-large
  text-align: center
  padding: .9em
h1
  font-size: x-large
h2
  font-size: large
h3
  font-size: medium
a
  padding: 2px
  color: blue
  &.exists
    &:hover
      background-color: blue
      text-decoration: none
      color: white
  &.unknown
    color: gray
    &:hover
      background-color: gray
      color: white
      text-decoration: none
  &.cancel
    color: red
    &:hover
      text-decoration: none
      background-color: red
      color: white
blockquote
  background-color: #f9f9f9
  padding: 5px 5px
  margin: 0
  margin-bottom: 2em
  outline: #eee solid 1px
  font-size: 0.9em
  cite
    font-weight: bold
    padding-left: 2em
code
  background-color: #eee
  font-size: smaller
pre
  padding: 5px 5px
  overflow: auto
  font-family: fixed
  line-height: 1em
  border-right: 1px solid #ccc
  border-bottom: 1px solid #ccc
  background-color: #eee
textarea
  font-family: courrier
  font-size: .9em
  border: 2px solid #ccc
  display: block
  padding: .5em
  height: 37em
  width: 100%
  line-height: 18px
input.submit
  font-weight: bold

#content
  max-width: 48em
  margin: auto
  padding: 2em
ul#pages_list
  list-style-type: none
  margin: 0
  padding: 0
  li
    padding: 5px
    &.odd
      background-color: #D3D3D3
    a
      text-decoration: none
.highlight
  background-color: #f8ec11
.done
  font-size: x-small
  color: #999
table
  text-align: center
  width: 100%
  border: none
  border-collapse: collapse
  border-spacing: 0px
th
  color: #FFF
  background-color: #3F3F3F
  border-bottom: 1px solid black
  padding: 2px
tr
  border-bottom: 1px solid black
