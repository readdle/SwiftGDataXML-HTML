Pod::Spec.new do |s|

  s.name         = "SwiftGDataXML_HTML"
  s.version      = "1.0.0"
  s.summary      = "SwiftGDataXML_HTML"
  s.description  = <<-DESC
                  SwiftGDataXML_HTML
                   DESC

  s.homepage     = "https://github.com/readdle/SwiftGDataXML-HTML.git"
  s.license      = { :type => 'Copyright 2021 Readdle Inc.', :text => 'Copyright 2021 Readdle Inc.' }
  s.author       = { "Andrew Druk" => "adruk@readdle.com" }
  s.source       = { :git => "git@github.com:readdle/SwiftGDataXML-HTML.git" }
  s.platforms    = { :ios => "10.0", :osx => "10.12" }


  s.source_files = "Sources/SwiftGDataXML_HTML/*.swift"
  s.requires_arc = true

  s.library      = "xml2"
  s.xcconfig     = { "HEADER_SEARCH_PATHS" => "$(SDKROOT)/usr/include/libxml2" }

end