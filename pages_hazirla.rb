#!/usr/bin/env ruby
# encoding: utf-8
#
# pages_hazirla.rb — kopyayı GitHub Pages alt dizininde çalışacak hale getirir.
#
# Kopya /sitecopy/kopyalar/<kim>/ altında yayınlandığı için, dosyaların içindeki
# kök mutlak yollar (/assets/x.css gibi) kırılır. Bu betik her dosyayı kendi
# klasörüne göre göreli yola çevirir.
#
#   ruby pages_hazirla.rb docs/kopyalar/<kim>

require 'pathname'

kok = ARGV[0].to_s
unless !kok.empty? && File.directory?(kok)
  warn 'Kullanım: ruby pages_hazirla.rb <kopya-klasörü>'
  exit 1
end

KOK = File.expand_path(kok)
HTML_UZANTI = %w[.html .htm .xhtml].freeze
CSS_UZANTI  = %w[.css].freeze

def derinlik(yol)
  Pathname.new(File.dirname(yol)).relative_path_from(Pathname.new(KOK)).to_s
          .split('/').reject { |p| p.empty? || p == '.' }.size
end

def duzelt(metin, onek)
  # href="/x"  src='/x'  action="/x"  ...  ve  url(/x)
  metin = metin.gsub(%r{((?:href|src|action|poster|data-src|data-href)\s*=\s*["'])/(?!/)}i) do
    "#{Regexp.last_match(1)}#{onek}"
  end
  metin.gsub(%r{(url\(\s*["']?)/(?!/)}i) do
    "#{Regexp.last_match(1)}#{onek}"
  end
end

sayac = 0
atlanan = 0

Dir.glob(File.join(KOK, '**', '*')).sort.each do |dosya|
  next unless File.file?(dosya)

  uzanti = File.extname(dosya).downcase
  next unless HTML_UZANTI.include?(uzanti) || CSS_UZANTI.include?(uzanti)

  ham = File.binread(dosya)
  metin = ham.dup.force_encoding(Encoding::UTF_8)
  unless metin.valid_encoding?
    metin = ham.dup.force_encoding(Encoding::BINARY)
  end

  d = derinlik(dosya)
  onek = d.zero? ? '' : '../' * d
  yeni = duzelt(metin, onek)

  if yeni == metin
    atlanan += 1
    next
  end

  File.binwrite(dosya, yeni)
  sayac += 1
end

puts "  ✓ #{sayac} dosyada yollar göreli hale getirildi (#{atlanan} dosya zaten uygundu)"
