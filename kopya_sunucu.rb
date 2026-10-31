#!/usr/bin/env ruby
# encoding: utf-8
#
# kopya_sunucu.rb — Site Kopyala web paneli
#
# Tarayıcıdan URL yapıştırırsın; site_kopyala.rb arka planda çalışır,
# ilerleme satırları canlı görünür ve kopyalanan site bitiminde
# Chrome'da http://localhost:PORT/site/<id>/ adresinde açılır.
#
#   Çalıştır: ruby kopya_sunucu.rb
#   Ardından: http://localhost:8787

require 'webrick'
require 'json'
require 'rbconfig'
require 'fileutils'
require 'securerandom'
require 'time'
require 'uri'
require 'socket'
require 'net/http'
require 'zlib'
require 'stringio'

# Sunucu modu: barındırma servislerinde (Render, Fly, Docker) çalışırken açılır.
# Açıkken yalnızca 0.0.0.0'a bağlanır, kopyalar ayrı portlarda değil
# /site/<kim>/ altında tek adresten servis edilir.
SUNUCU_MODU = ENV['KOPYA_MOD'] == 'sunucu' || !ENV['PORT'].to_s.empty?

PORT      = Integer(ENV['KOPYA_PORT'] || ENV['PORT'] || 8787)
BAG_ADRESI = SUNUCU_MODU ? '0.0.0.0' : '127.0.0.1'
TABAN     = File.expand_path(__dir__)
ARAC      = File.join(TABAN, 'site_kopyala.rb')
KOPYALAR  = begin
  ozel = ENV['KOPYA_KOPYALAR'].to_s
  ozel.empty? ? File.join(TABAN, 'kopyalar') : File.expand_path(ozel)
end

VARSAYILAN_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
                'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 ' \
                'Safari/537.36 SiteKopyala/1.0'

FileUtils.mkdir_p(KOPYALAR)
raise "Araç bulunamadı: #{ARAC}" unless File.file?(ARAC)

MIME = WEBrick::HTTPUtils::DefaultMimeTypes.merge(
  'woff2' => 'font/woff2', 'woff' => 'font/woff', 'ttf' => 'font/ttf',
  'otf' => 'font/otf', 'eot' => 'application/vnd.ms-fontobject',
  'webmanifest' => 'application/manifest+json', 'map' => 'application/json',
  'avif' => 'image/avif', 'mjs' => 'text/javascript', 'ico' => 'image/x-icon',
  'mp4' => 'video/mp4', 'webm' => 'video/webm', 'webp' => 'image/webp'
).freeze

@joblar = {}
@kilit  = Mutex.new

@clone_sunucular = {}        # kim => port
@clone_sunucu_nesneleri = {} # kim => WEBrick nesnesi
@clone_kilit = Mutex.new

@clone_kok = {}        # kim => orijinal site kök adresi (https://x.com/)
@yakalama_sayi = {}    # kim => canlı yakalanan istek sayısı

# ------------------------------------------------------------ yardımcılar ---
def yanit_json(res, nesne, kod = 200)
  res.status = kod
  res['Content-Type'] = 'application/json; charset=utf-8'
  res['Cache-Control'] = 'no-store'
  res.body = JSON.generate(nesne)
end

def yanit_html(res, metin, kod = 200)
  res.status = kod
  res['Content-Type'] = 'text/html; charset=utf-8'
  res.body = metin
end

def chrome_ac(url)
  return if SUNUCU_MODU

  Thread.new do
    sleep 0.3
    system('open', '-a', 'Google Chrome', url) || system('open', url)
  rescue StandardError
    nil
  end
end

# KOPYA_KULLANICI / KOPYA_SIFRE tanımlıysa paneli HTTP Basic ile korur.
# Sunucu modunda herkese açık çalışacağı için varsayılan olarak önerilir.
def sifre_korumali?
  !ENV['KOPYA_KULLANICI'].to_s.empty? && !ENV['KOPYA_SIFRE'].to_s.empty?
end

def yetkili_mi?(req)
  return true unless sifre_korumali?

  ham = req['authorization'].to_s
  return false unless ham.start_with?('Basic ')

  cozulen = begin
    ham.sub(/\ABasic /i, '').unpack1('m').to_s
  rescue StandardError
    ''
  end
  beklenen = "#{ENV['KOPYA_KULLANICI']}:#{ENV['KOPYA_SIFRE']}"
  cozulen.bytesize == beklenen.bytesize && cozulen == beklenen
end

def giris_iste(res)
  res.status = 401
  res['WWW-Authenticate'] = 'Basic realm="sitecopy", charset="UTF-8"'
  res['Content-Type'] = 'text/html; charset=utf-8'
  res.body = '<h1>Giriş gerekli</h1>'
end

def gecerli_url?(u)
  return false if u.nil? || u.empty?
  uri = URI.parse(u)
  uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
rescue URI::InvalidURIError
  false
end

def klansor_adi(kim)
  return nil unless kim.to_s =~ /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  klasor = File.join(KOPYALAR, kim)
  File.directory?(klasor) ? klasor : nil
end

# Boş bir TCP portu bulur (9100–9199 aralığı)
def bos_port_bul(baslangic = 9100, bitis = 9199)
  (baslangic..bitis).each do |p|
    begin
      TCPServer.new('127.0.0.1', p).close
      return p
    rescue Errno::EADDRINUSE
      next
    end
  end
  nil
end

# Bir dosyayı (MIME + UTF-8 bilgisiyle) yanıta yazar
def dosya_ver(res, tam)
  uz = File.extname(tam).downcase.delete('.')
  tip = MIME[uz] || 'application/octet-stream'
  tip += '; charset=UTF-8' if tip.start_with?('text/') ||
        %w[application/javascript application/json application/manifest+json].include?(tip)
  res['Content-Type'] = tip
  res['Cache-Control'] = 'no-cache'
  res.body = File.binread(tam)
end

# Çalışma anında kurulan uzak isteklerin (_dis köprüsü) uğramaması gereken
# izleyici/reklam alanları — sessizce 204 döner, dışarı istek gitmez
IZLEYICI_ETKI = %w[
  google-analytics.com googletagmanager.com doubleclick.net googleadservices.com
  googlesyndication.com connect.facebook.net hotjar.com mixpanel.com segment.com
  segment.io amplitude.com sentry.io newrelic.com nr-data.net criteo.com
  taboola.com outbrain.com adnxs.com pubmatic.com scorecardresearch.com
  quantserve.com sharethis.com platform-api.sharethis.com cookielaw.org
  cookiebot.com onetrust.com yandex.ru mc.yandex.ru klaviyo.com
  stripe.com js.stripe.com realtimely.io
].freeze

def izleyici_mi?(konuk)
  IZLEYICI_ETKI.any? { |d| konuk == d || konuk.end_with?(".#{d}") }
end

# Sorgulu önbellek dosya adı: /api.php + route=bootstrap → api.php__route=bootstrap
def cache_adi(yol, sorgu)
  return yol if sorgu.to_s.empty?
  eki = sorgu.split('&').map { |p| p.tr('^A-Za-z0-9_.=-', '_') }.sort.join('&')[0, 120]
  eki.empty? ? yol : "#{yol}__#{eki}"
end

# İlk istekte eksik dinamik kaynağı (API yanıtı, görsel vb.) orijinal
# siteden indirir, diske önbelleğe alır ve servis eder. Sonraki
# açılışlar tamamen çevrimdışıdır.
def canli_yakala(kim, yol, sorgu)
  kok = @clone_kilit.synchronize { @clone_kok[kim] }
  return nil if kok.to_s.empty?
  devam = @clone_kilit.synchronize do
    @yakalama_sayi[kim] ||= 0
    if @yakalama_sayi[kim] >= 3000
      false
    else
      @yakalama_sayi[kim] += 1
      true
    end
  end
  return nil unless devam

  begin
    m = yol.match(%r{\A/_dis/([^/]+)(/.*)?\z})
    if m
      # köprünün yönlendirdiği uzak alan adı — doğrudan o host'tan yakala
      konuk = m[1].downcase
      unless konuk =~ /\A[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+\z/
        return :engelli # geçersiz host adı
      end
      return :engelli if izleyici_mi?(konuk)
      sema = (URI.parse(kok.to_s).scheme rescue 'https') || 'https'
      kalan = m[2].to_s.empty? ? '/' : m[2]
      # izleyici uçları — matomo/piwik beacon'ları hiçbir zaman yakalanmaz
      return :engelli if kalan =~ %r{/(?:matomo|piwik)\.(?:php|js)\z}i
      hedef = URI.parse("#{sema}://#{konuk}#{kalan}")
    else
      # kök-göreli yol: istek yolu her zaman alan adının köküne göre çözülür
      ku = URI.parse(kok.to_s)
      taban_kok = "#{ku.scheme}://#{ku.host}" \
                  "#{ku.port && ![80, 443].include?(ku.port) ? ':' + ku.port.to_s : ''}/"
      hedef = URI.join(taban_kok, yol.sub(%r{\A/}, ''))
    end
    hedef.query = sorgu unless sorgu.to_s.empty?
  rescue StandardError
    return nil
  end

  yanit = nil
  3.downto(0) do |kalan|
    begin
      http = Net::HTTP.new(hedef.host, hedef.port)
      http.use_ssl = hedef.scheme == 'https'
      http.open_timeout = 20
      http.read_timeout = 40
      istek = Net::HTTP::Get.new(hedef.request_uri)
      istek['User-Agent'] = VARSAYILAN_UA
      istek['Accept-Encoding'] = 'identity'
      yanit = nil
      http.request(istek) { |y| yanit = y }
      if yanit.is_a?(Net::HTTPRedirection) && kalan > 0
        hedef = URI.join(hedef.to_s, yanit['location'].to_s)
        next
      end
      break
    rescue StandardError
      return nil if kalan.zero?
      sleep 0.5
    end
  end
  return nil unless yanit.is_a?(Net::HTTPSuccess)

  ct = yanit['content-type'].to_s
  govde = yanit.body.to_s.dup.force_encoding(Encoding::BINARY)
  if yanit['content-encoding'].to_s.downcase == 'gzip'
    govde = (Zlib::GzipReader.new(StringIO.new(govde)).read rescue govde).to_s
              .force_encoding(Encoding::BINARY)
  end
  # Sayfa değil, kaynak yakala: gerçek HTML sayfaları reddet; ancak
  # text/html etiketli küçük düz değer yanıtları (ör. weight.php → "0")
  # kaynak olarak kabul edilir.
  if ct.include?('html')
    duz_mu = govde.bytesize <= 1024 && !govde.include?('<')
    return nil unless duz_mu
  end

  return nil if govde.bytesize > 50 * 1024 * 1024

  klasor = File.join(KOPYALAR, kim)
  dosya = File.join(klasor, cache_adi(yol, sorgu))
  FileUtils.mkdir_p(File.dirname(dosya))
  File.binwrite(dosya, govde)
  [govde, ct.empty? ? 'application/octet-stream' : ct]
rescue StandardError
  nil
end

# Kopyanın KENDİ sunucusu: dosyaları kök dizinden (/) servis eder.
# Böylece SPA'ların mutlak yolları (/assets, /urunler, React Router
# rotaları) doğru çözülür. Uzantısız ve bulunamayan istemci tarafı
# rotalar root index.html'e (SPA fallback) düşer. Bulunamayan dinamik
# kaynaklar (API, görsel) ilk istekte orijinal siteden yakalanır.
def clone_ver(req, res, klasor, kim)
  ham = req.path.to_s
  ham = '/' if ham.empty?
  aday = File.expand_path(File.join(klasor, ham))
  unless aday == klasor || aday.start_with?(klasor + File::SEPARATOR)
    res.status = 403
    res.body = 'Yasak'
    return
  end

  sorgu = req.request_uri.query.to_s

  # Cloudflare beacon gibi çevrimdışı anlamsız uçlar sessizce geçilir
  if ham.start_with?('/cdn-cgi/')
    res.status = 204
    res.body = ''
    return
  end

  # 1) sorgulu önbellek (örn. api.php__route=bootstrap)
  unless sorgu.empty?
    onbellek = File.join(klasor, cache_adi(ham, sorgu))
    if File.file?(onbellek)
      dosya_ver(res, onbellek)
      return
    end
  end

  if File.directory?(aday)
    unless ham.end_with?('/')
      res.status = 301
      res['Location'] = ham + '/'
      res.body = ''
      return
    end
    aday = File.join(aday, 'index.html')
  end

  if File.file?(aday)
    dosya_ver(res, aday)
    return
  end

  belge_mi = req['sec-fetch-dest'].to_s == 'document' ||
             (req['accept'].to_s.include?('text/html') && req['sec-fetch-dest'].to_s.empty?)

  # 2) belge gezintisi ve uzantısız rota → SPA fallback (root index)
  if belge_mi && File.extname(ham).empty?
    ana = File.join(klasor, 'index.html')
    if File.file?(ana)
      dosya_ver(res, ana)
      return
    end
  end

  # 3) dinamik kaynak (fetch/img/css vb.) → orijinal siteden yakala
  unless belge_mi
    sonuc = canli_yakala(kim, ham, sorgu)
    if sonuc == :engelli
      # izleyici/reklam isteği — sessizce geç, dışarı istek gitmesin
      res.status = 204
      res.body = ''
      return
    end
    govde, ct = sonuc
    if govde
      res['Content-Type'] = ct
      res['Cache-Control'] = 'no-cache'
      res.body = govde
      return
    end
  end

  res.status = 404
  res['Content-Type'] = 'text/html; charset=utf-8'
  res.body = '<h1>404 — Bulunamadı</h1>'
rescue StandardError => e
  res.status = 500
  res.body = "Sunucu hatası: #{e.message}"
end

# Kopya için kök dizinli yerel sunucu başlatır; port döner
def clone_sunucu_baslat(kim, klasor, oncelikli_port = nil)
  # Sunucu modunda her kopya ayrı portta dinleyemez; hepsi /site/<kim>/
  # altından tek adresten servis edilir.
  return nil if SUNUCU_MODU

  @clone_kilit.synchronize do
    return @clone_sunucular[kim] if @clone_sunucular[kim]
    port = nil
    if oncelikli_port.to_i.between?(1024, 65_535)
      begin
        TCPServer.new('127.0.0.1', oncelikli_port.to_i).close
        port = oncelikli_port.to_i
      rescue Errno::EADDRINUSE
        port = nil
      end
    end
    port ||= bos_port_bul
    return nil unless port

    s = WEBrick::HTTPServer.new(
      Port: port,
      BindAddress: '127.0.0.1',
      AccessLog: [],
      Logger: WEBrick::Log.new(File::NULL)
    )
    s.mount_proc('/') { |req, res| clone_ver(req, res, klasor, kim) }
    @clone_sunucular[kim] = port
    @clone_sunucu_nesneleri[kim] = s
    Thread.new { s.start }
    port
  end
end

# Kopyanın giriş sayfasını bulur (kökten göreli dizin; kökteyse '').
# Sıra: manifest'teki URL yolu → en sığ index.html (tr tercihli).
def kopya_girisi(klasor, b)
  return '' if File.file?(File.join(klasor, 'index.html'))
  parca = ((URI.parse(b['url'].to_s).path rescue '').to_s).split('/').reject(&:empty?)
  while parca.any?
    return parca.join('/') if File.file?(File.join(klasor, *parca, 'index.html'))
    parca.pop
  end
  hepsi = Dir.glob(File.join(klasor, '**', 'index.html')).reject do |p|
    p.split(File::SEPARATOR).any? { |e| e.start_with?('_') }
  end
  en_iyisi = hepsi.min_by do |p|
    d = p[(klasor.length + 1)..].to_s
    [d.count('/'), d.start_with?('tr/') ? 0 : 1, d.length]
  end
  en_iyisi && File.dirname(en_iyisi)[(klasor.length + 1)..].to_s
end

# Kök index.html yoksa klasöre küçük bir yönlendirme sayfası yazar; böylece
# kopya kendi sunucusunda / açıldığında giriş sayfasına düşer.
def kok_index_yaz(klasor, giris)
  return if giris.nil? || File.file?(File.join(klasor, 'index.html'))
  hedef = '/' + (giris.empty? ? '' : giris + '/')
  html = <<~HTML
    <!DOCTYPE html>
    <html lang="tr">
    <head>
      <meta charset="UTF-8">
      <meta http-equiv="refresh" content="0; url=#{hedef}">
      <title>Yönlendiriliyor…</title>
    </head>
    <body style="font-family:-apple-system,sans-serif; text-align:center; margin-top:40vh; color:#555">
      <p><a href="#{hedef}">Kopyanın giriş sayfasına git</a></p>
    </body>
    </html>
  HTML
  File.write(File.join(klasor, 'index.html'), html)
rescue StandardError
  nil
end

def kopya_listesi
  Dir.glob(File.join(KOPYALAR, '*')).select { |d| File.directory?(d) }.map do |d|
    kim = File.basename(d)
    bilgi_dosyasi = File.join(d, '.kopya.json')
    b = File.file?(bilgi_dosyasi) ? (JSON.parse(File.read(bilgi_dosyasi)) rescue {}) : {}
    giris = kopya_girisi(d, b)
    kok_index_yaz(d, giris)
    port = @clone_sunucular[kim] || b['port']
    port = nil if SUNUCU_MODU # sunucu modunda kopyalar /site/<kim>/ altında
    html_sayisi = b['sayfa'].to_i
    html_sayisi = Dir.glob(File.join(d, '**', '*.html')).size if html_sayisi.zero?
    alan = (URI.parse(b['url'].to_s).host rescue nil).to_s.sub(/\Awww\./, '')
    if alan.empty?
      # Manifest yok: _dis köprüsünden sitenin kendi alanını tahmin et —
      # CDN/altyapı alanlarını (cdn.*, cloudflare, google …) ele.
      adaylar = Dir.glob(File.join(d, '_dis', '*')).select { |p| File.directory?(p) }
                  .map { |p| File.basename(p).sub(/\Awww\./, '') }
      altyapi = /\A(cdn|ajax|assets|static|fonts|img|images|js|css)[.-]|jsdelivr|cloudflare|google|gstatic|appleid|jquery|unpkg|bootstrapcdn|algolia|stripe|facebook|hotjar|sentry|realtimely/
      alan = (adaylar.reject { |a| a =~ altyapi }.min || adaylar.min).to_s
    end
    {
      kim: kim,
      url: b['url'].to_s,
      alan: (alan.nil? || alan.empty? ? kim : alan),
      giris: giris,
      tarih: (b['tarih'].to_s.empty? ? File.mtime(d).iso8601 : b['tarih'].to_s),
      sayfa: html_sayisi,
      kok: b['kok'].to_s,
      port: (port.to_i if port.to_i.between?(1024, 65_535))
    }
  end.select { |k| !k[:giris].nil? }.sort_by { |k| k[:tarih] }.reverse
end

# İşi arka planda çalıştırır, satırları job[:log]'a yazar
def kopyayi_baslat(job)
  Thread.new do
    job[:durum] = 'calisiyor'
    begin
      komut = [RbConfig.ruby, ARAC, job[:url], '-o', job[:klasor], '-d', job[:derinlik].to_s]
      IO.popen(komut, 'r', err: [:child, :out]) do |io|
        while (satir = io.gets)
          job[:log] << satir.chomp
          job[:log].shift if job[:log].size > 4000
        end
      end
      kod = $?.exitstatus
      html_sayisi = Dir.glob(File.join(job[:klasor], '**', '*.html')).size
      if kod == 0 && html_sayisi > 0
        port = clone_sunucu_baslat(job[:kim], job[:klasor])
        job[:port] = port
        job[:site_url] = "http://localhost:#{port}/" if port
        kok = (URI.join(job[:url], '/').to_s rescue nil)
        job[:kok] = kok
        @clone_kilit.synchronize { @clone_kok[job[:kim]] = kok }
        job[:durum] = 'bitti'
        job[:sayfa] = html_sayisi
        File.write(File.join(job[:klasor], '.kopya.json'), JSON.generate(
          'url' => job[:url], 'tarih' => Time.now.iso8601, 'sayfa' => html_sayisi,
          'port' => port, 'kok' => kok
        ))
        job[:log] << "✓ Tamamlandı — #{html_sayisi} HTML dosyası kaydedildi."
        job[:log] << "  Yerel adres: #{job[:site_url]}" if port
        chrome_ac(job[:site_url]) if job[:chrome]
      else
        job[:durum] = 'hata'
        job[:log] << "✗ Kopyalama başarısız oldu (çıkış kodu #{kod}, HTML: #{html_sayisi})."
        job[:log] << "  İpucu: URL'yi ve internet bağlantını kontrol et; --acik ile ayrıntı al."
      end
    rescue StandardError => e
      job[:durum] = 'hata'
      job[:log] << "✗ Sunucu hatası: #{e.class}: #{e.message}"
    end
  end
end

# Kopyalanmış siteyi (path traversal'a karşı korunarak) servis eder
# Sunucu modunda kopya /site/<kim>/ altında servis edildiği için, kopyanın
# içindeki kök mutlak yolları (/assets/x.css gibi) bu öneğe taşır.
def kok_yol_duzelt(govde, kim)
  onek = "/site/#{kim}/"
  metin = govde.dup.force_encoding(Encoding::BINARY)
  metin = metin.gsub(%r{((?:href|src|action|poster|data-src)\s*=\s*["'])/(?!/|site/)}in) { "#{Regexp.last_match(1)}#{onek}" }
  metin.gsub(%r{(url\(\s*["']?)/(?!/|site/)}in) { "#{Regexp.last_match(1)}#{onek}" }
end

def site_ver(req, res)
  kalan = req.path.sub(%r{\A/site/}, '')
  kim, gerisi = kalan.split('/', 2)
  klasor = klansor_adi(kim)
  unless klasor
    yanit_html(res, '<h1>404 — Kopya bulunamadı</h1><p><a href="/">Panele dön</a></p>', 404)
    return
  end

  gerisi = gerisi.to_s
  gerisi = 'index.html' if gerisi.empty? || gerisi.end_with?('/')
  tam = File.expand_path(File.join(klasor, gerisi))
  unless tam == klasor || tam.start_with?(klasor + File::SEPARATOR)
    res.status = 403
    res.body = 'Yasak'
    return
  end

  if File.directory?(tam)
    ham = req.request_uri.path.to_s
    res.status = 301
    res['Location'] = ham.end_with?('/') ? ham : ham + '/'
    res.body = ''
    return
  end
  unless File.file?(tam)
    yanit_html(res, "<h1>404 — #{File.basename(tam)} yok</h1><p><a href=\"/\">Panele dön</a></p>", 404)
    return
  end

  uz = File.extname(tam).downcase.delete('.')
  tip = MIME[uz] || 'application/octet-stream'
  tip += '; charset=UTF-8' if tip.start_with?('text/') ||
                              %w[application/javascript application/json application/manifest+json].include?(tip)
  res['Content-Type'] = tip
  res['Cache-Control'] = 'no-cache'
  govde = File.binread(tam)
  if SUNUCU_MODU && (tip.start_with?('text/html') || tip.start_with?('text/css'))
    govde = kok_yol_duzelt(govde, kim)
  end
  res.body = govde
rescue StandardError => e
  res.status = 500
  res.body = "Sunucu hatası: #{e.message}"
end

# ---------------------------------------------------------------- HTML ---
ANA_SAYFA = <<~HTML
  <!DOCTYPE html>
  <html lang="tr">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>sitecopy</title>
    <style>
      /* siyah (varsayılan) ve beyaz mod */
      :root { --bg:#000; --yazi:#fff; --cizgi:#fff; --dugmeArka:#fff; --dugmeYazi:#000; }
      body.acik { --bg:#fff; --yazi:#000; --cizgi:#000; --dugmeArka:#000; --dugmeYazi:#fff; }

      * { box-sizing:border-box; }
      body { margin:0; background:var(--bg); color:var(--yazi);
             font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
             font-size:15px; line-height:1.5; }
      .kabuk { max-width:680px; margin:0 auto; padding:56px 20px 32px;
               min-height:100vh; display:flex; flex-direction:column; }

      .ust { display:flex; align-items:baseline; justify-content:space-between; gap:12px; }
      h1 { margin:0; font-size:28px; font-weight:700; letter-spacing:-1px; }
      .tema { padding:6px 12px; font-size:13px; color:var(--yazi); background:none;
              border:1px solid var(--cizgi); cursor:pointer; }
      .tema:hover { background:var(--yazi); color:var(--bg); }
      .sayac { font-size:13px; opacity:.55; }

      hr { border:0; border-top:1px solid var(--cizgi); margin:36px 0 10px; }

      /* form */
      form { display:flex; flex-wrap:wrap; gap:12px; align-items:center; margin-top:34px; }
      input#url { flex:1 1 240px; padding:10px 2px; font-size:16px; color:var(--yazi);
                  background:none; border:0; border-bottom:1px solid var(--cizgi); outline:none; }
      input#url::placeholder { color:inherit; opacity:.35; }
      select { padding:10px 2px; font-size:14px; color:var(--yazi); background:none;
               border:0; border-bottom:1px solid var(--cizgi); outline:none; cursor:pointer; }
      option { color:#000; background:#fff; }
      button.ana { padding:11px 22px; font-size:15px; font-weight:600; color:var(--dugmeYazi);
                   background:var(--dugmeArka); border:1px solid var(--dugmeArka); cursor:pointer; }
      button.ana:hover:not(:disabled) { opacity:.8; }
      button.ana:disabled { opacity:.35; cursor:wait; }
      .anahtar { display:flex; align-items:center; gap:8px; font-size:14px; cursor:pointer; }
      .anahtar input { width:15px; height:15px; accent-color:var(--yazi); }
      .imza { text-align:center; margin:auto 0 0; padding-top:48px; font-size:13px;
              letter-spacing:2px; opacity:.5; }

      /* durum */
      #durumKartı { margin-top:34px; display:none; }
      #durumKartı p { margin:0; }
      .rozet { display:inline-block; font-size:14px; font-weight:600; }
      .rozet .nokta { display:inline-block; width:8px; height:8px; background:currentColor;
                      margin-right:7px; vertical-align:1px; }
      .rozet.calisiyor .nokta { animation:yanip 1s steps(2, start) infinite; }
      .rozet.bitti .nokta, .rozet.hata .nokta { opacity:.3; }
      @keyframes yanip { 50% { opacity:0; } }
      #kisaBilgi { font-size:13px; opacity:.55; margin-left:10px; }

      .ilerleme { height:1px; background:var(--cizgi); margin:16px 0 0; display:none; }
      .ilerleme i { display:block; height:100%; width:40%; background:var(--yazi);
                    animation:kayma 1.1s linear infinite; }
      @keyframes kayma { from { margin-left:-40%; } to { margin-left:100%; } }

      #konsol { margin-top:16px; max-height:240px; overflow-y:auto; display:none;
                font:12px/1.75 ui-monospace,SFMono-Regular,Menlo,monospace;
                white-space:pre-wrap; word-break:break-all; }
      #konsol .ok { font-weight:700; }
      #konsol .hata { font-weight:700; }
      #konsol .sol { opacity:.55; }

      /* başarı */
      #basari { margin-top:34px; display:none; }
      #basari .bas { font-size:16px; font-weight:700; }
      #basariBilgi { font-size:13px; opacity:.55; }
      #basari .adres { display:block; margin:12px 0 16px; font-size:14px; color:inherit;
                       word-break:break-all; text-decoration:underline; }
      button.sol { padding:11px 20px; font-size:15px; color:var(--yazi); background:none;
                   border:1px solid var(--cizgi); cursor:pointer; margin-left:8px; }
      button.sol:hover { background:var(--yazi); color:var(--bg); }

      /* liste */
      .yon { display:flex; align-items:baseline; justify-content:space-between; gap:10px;
             margin:38px 0 0; }
      .yon b { font-size:16px; }
      .yon .sayac { margin-left:8px; }
      .yon button { padding:0; font-size:13px; color:inherit; background:none; border:0;
                    text-decoration:underline; cursor:pointer; }
      #liste { border-top:1px solid var(--cizgi); margin-top:10px; }
      .kopya { display:flex; align-items:baseline; gap:14px; flex-wrap:wrap;
               padding:12px 0; border-bottom:1px solid var(--cizgi); }
      .kopya .alan { font-weight:600; }
      .kopya .meta { flex:1 1 160px; font-size:13px; opacity:.55; }
      .kopya .eylem { display:flex; gap:14px; font-size:13px; }
      .link { padding:0; font:inherit; font-size:13px; color:inherit; background:none;
              border:0; text-decoration:underline; cursor:pointer; }
      .bos { padding:22px 0; font-size:14px; opacity:.55; }

      #tost { position:fixed; bottom:24px; left:50%; transform:translateX(-50%);
              background:var(--yazi); color:var(--bg); padding:10px 18px; font-size:14px; z-index:99;
              opacity:0; pointer-events:none; transition:opacity .15s; }
      #tost.gor { opacity:1; }

      @media (max-width:600px) { h1 { font-size:24px; } }
    </style>
  </head>
  <body>
    <div class="kabuk">

      <div class="ust">
        <h1>sitecopy</h1>
        <button class="tema" id="temaBtn" type="button">beyaz</button>
      </div>

      <form id="form">
        <input id="url" type="text" placeholder="https://ornek.com" autocomplete="off" spellcheck="false" required>
        <select id="derinlik" title="Tarama derinliği">
          <option value="2">derinlik 2</option>
          <option value="4">derinlik 4</option>
          <option value="8">derinlik 8</option>
          <option value="12" selected>derinlik tam</option>
        </select>
        <button class="ana" id="dugme" type="submit">Kopyala</button>
        <label class="anahtar" title="Bitince Chrome'da otomatik açılır">
          <input type="checkbox" id="chrome" checked>
          Chrome'da aç
        </label>
      </form>

      <div id="durumKartı">
        <p><span class="rozet" id="rozet"><span class="nokta"></span><span id="rozetMetin">Bekliyor</span></span><span id="kisaBilgi"></span></p>
        <div class="ilerleme" id="ilerleme"><i></i></div>
        <div id="konsol"></div>
      </div>

      <div id="basari">
        <div class="bas">Kopya hazır</div>
        <div id="basariBilgi"></div>
        <a class="adres" id="basariAdres" href="#" target="_blank" rel="noopener"></a>
        <button class="ana" id="btnAc" type="button">Chrome'da Aç</button>
        <button class="sol" id="btnBul" type="button">Klasörde Göster</button>
      </div>

      <hr>
      <div class="yon">
        <span><b>Kopyalar</b><span class="sayac" id="listeSayac"></span></span>
        <button id="yenileBtn" type="button">yenile</button>
      </div>
      <div id="liste"></div>

      <p class="sayac" style="margin:28px 0 0">
        Kopya <b id="istatKopya">0</b> · Sayfa <b id="istatSayfa">0</b> · Port <b id="istatPort">0</b>
      </p>

      <p class="imza">wer1x</p>

    </div>
    <div id="tost"></div>

    <script>
      let aktifId = null, indis = 0, zamanlayici = null;

      const $ = id => document.getElementById(id);
      const konsol = $('konsol');

      // tema: her zaman siyahta başlar, düğme beyaza çevirir
      $('temaBtn').addEventListener('click', () => {
        const acik = document.body.classList.toggle('acik');
        $('temaBtn').textContent = acik ? 'siyah' : 'beyaz';
      });

      function tost(metin) {
        const t = $('tost');
        t.textContent = metin;
        t.classList.add('gor');
        setTimeout(() => t.classList.remove('gor'), 3800);
      }

      function rozetAyarla(durum) {
        const r = $('rozet');
        r.className = 'rozet ' + durum;
        const metin = { calisiyor: 'Kopyalanıyor', bitti: 'Tamamlandı',
                        hata: 'Hata', bekliyor: 'Başlatılıyor' }[durum] || durum;
        $('rozetMetin').textContent = metin;
        $('ilerleme').style.display = durum === 'calisiyor' ? 'block' : 'none';
      }

      function kunye(t) {
        try {
          return new Date(t).toLocaleString('tr-TR',
            { day:'2-digit', month:'short', year:'numeric', hour:'2-digit', minute:'2-digit' });
        } catch (e) { return t || ''; }
      }

      function logEkle(satirlar) {
        for (const s of satirlar) {
          const div = document.createElement('div');
          if (s.startsWith('  ✓') || s.startsWith('✓')) div.className = 'ok';
          else if (s.startsWith('  ✗') || s.startsWith('!')) div.className = 'hata';
          else if (s.startsWith('  ·')) div.className = 'sol';
          div.textContent = s;
          konsol.appendChild(div);
        }
        while (konsol.children.length > 400) konsol.removeChild(konsol.firstChild);
        konsol.scrollTop = konsol.scrollHeight;
      }

      $('form').addEventListener('submit', async e => {
        e.preventDefault();
        const url = $('url').value.trim();
        if (!url) return;
        $('dugme').disabled = true;
        konsol.innerHTML = ''; indis = 0;
        konsol.style.display = 'block';
        $('durumKartı').style.display = 'block';
        $('basari').style.display = 'none';
        rozetAyarla('bekliyor');
        $('kisaBilgi').textContent = url;
        try {
          const cevap = await fetch('/api/kopyala', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({url, derinlik: +$('derinlik').value, chrome: $('chrome').checked})
          });
          const veri = await cevap.json();
          if (veri.hata) throw new Error(veri.hata);
          aktifId = veri.kim;
          anket();
          $('durumKartı').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        } catch (h) {
          rozetAyarla('hata');
          logEkle(['✗ ' + h.message]);
          tost('✗ ' + h.message);
          $('dugme').disabled = false;
        }
      });

      async function anket() {
        clearInterval(zamanlayici);
        zamanlayici = setInterval(async () => {
          try {
            const c = await fetch('/api/durum/' + aktifId + '?den=' + indis);
            const v = await c.json();
            if (v.yeni && v.yeni.length) { logEkle(v.yeni); indis = v.toplam; }
            if (v.durum !== 'calisiyor' && v.durum !== 'bekliyor') {
              clearInterval(zamanlayici);
              bitir(v);
            } else {
              rozetAyarla(v.durum);
            }
          } catch (_) { /* sunucuya yeni bağlanılıyor olabilir */ }
        }, 700);
      }

      function bitir(v) {
        $('dugme').disabled = false;
        rozetAyarla(v.durum);
        if (v.durum === 'bitti') {
          $('basari').style.display = 'block';
          $('basariAdres').textContent = v.url;
          $('basariAdres').href = v.url;
          $('basariBilgi').textContent = (v.sayfa || 0) + ' sayfa indirildi — ' + kunye(new Date());
          $('btnAc').onclick = () => window.open(v.url, '_blank');
          $('btnBul').onclick = () => fetch('/api/acik?kim=' + encodeURIComponent(aktifId));
          $('basari').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
          if (!$('chrome').checked) window.open(v.url, '_blank');
        } else {
          tost('✗ Kopyalama başarısız — konsolu kontrol et');
        }
        listeYukle();
      }

      async function listeYukle() {
        try {
          const c = await fetch('/api/liste');
          const liste = await c.json();
          $('istatKopya').textContent = liste.length;
          $('istatSayfa').textContent = liste.reduce((a, x) => a + (x.sayfa || 0), 0);
          $('istatPort').textContent = liste.filter(x => x.port).length;
          $('listeSayac').textContent = liste.length ? liste.length + ' kopya' : '';
          const k = $('liste');
          if (!liste.length) {
            k.innerHTML = '<div class="bos">Henüz kopya yok.</div>';
            return;
          }
          const adres = x => x.port ? 'http://localhost:' + x.port + '/' : '/site/' + x.kim + '/';
          k.innerHTML = liste.map((x, i) => {
            const parca = [(x.sayfa || 0) + ' sayfa'];
            if (x.port) parca.push(':' + x.port);
            if (x.tarih) parca.push(kunye(x.tarih));
            return '<div class="kopya">' +
              '<span class="alan"></span>' +
              '<span class="meta">' + parca.join(' · ') + '</span>' +
              '<span class="eylem">' +
                '<button class="link" data-ac="' + x.kim + '">aç</button>' +
                '<button class="link" data-kl="' + x.kim + '">klasör</button>' +
                '<button class="link" data-sil="' + x.kim + '">sil</button>' +
              '</span></div>';
          }).join('');
          liste.forEach((x, i) => {
            const kart = k.children[i];
            kart.querySelector('.alan').textContent =
              x.alan || (x.url || x.kim).replace(/^https?:[/][/]/, '').replace(/[/].*$/, '') || x.kim;
            kart.querySelector('[data-ac]').addEventListener('click', () => window.open(adres(x), '_blank'));
            kart.querySelector('[data-kl]').addEventListener('click', () => fetch('/api/acik?kim=' + encodeURIComponent(x.kim)));
            kart.querySelector('[data-sil]').addEventListener('click', async () => {
              if (!confirm('Bu kopya ve tüm dosyaları silinsin mi?')) return;
              await fetch('/api/kaldir?kim=' + encodeURIComponent(x.kim));
              listeYukle();
            });
          });
        } catch (_) { /* liste yüklenemedi */ }
      }

      $('yenileBtn').addEventListener('click', listeYukle);
      listeYukle();
    </script>
  </body>
  </html>
HTML

# ------------------------------------------------------------- sunucu ---
sunucu = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: BAG_ADRESI,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

sunucu.mount_proc('/') do |req, res|
  yol = req.path

  unless yetkili_mi?(req)
    giris_iste(res)
    next
  end

  if req.request_method == 'GET' && (yol == '/' || yol.empty?)
    yanit_html(res, ANA_SAYFA)

  elsif req.request_method == 'POST' && yol == '/api/kopyala'
    ham_govde = req.body
    ham_govde = ham_govde.read if ham_govde.respond_to?(:read)
    veri = (JSON.parse(ham_govde.to_s) rescue {})
    url = veri['url'].to_s.strip
    url = 'https://' + url unless url =~ %r{\Ahttps?://}i
    unless gecerli_url?(url)
      yanit_json(res, { hata: 'Geçersiz URL. Örn: https://ornek.com' }, 400)
      next
    end
    derinlik = veri['derinlik'].to_i
    derinlik = 12 unless derinlik.between?(1, 12)
    kim = Time.now.strftime('%Y%m%d-%H%M%S') + '-' + SecureRandom.hex(2)
    job = {
      kim: kim, url: url, derinlik: derinlik, durum: 'bekliyor', log: [],
      chrome: veri['chrome'] != false,
      klasor: File.join(KOPYALAR, kim),
      site_url: SUNUCU_MODU ? "/site/#{kim}/" : "http://localhost:#{PORT}/site/#{kim}/"
    }
    @kilit.synchronize { @joblar[kim] = job }
    kopyayi_baslat(job)
    yanit_json(res, { kim: kim, url: job[:site_url] })

  elsif req.request_method == 'GET' && yol.start_with?('/api/durum/')
    kim = yol.sub(%r{\A/api/durum/}, '').split('?').first
    job = @kilit.synchronize { @joblar[kim] }
    unless job
      yanit_json(res, { hata: 'iş bulunamadı' }, 404)
      next
    end
    den = begin
      Integer(req.query['den'].to_s)
    rescue StandardError
      0
    end
    den = 0 if den.negative?
    yeni, toplam = nil, nil
    @kilit.synchronize do
      toplam = job[:log].size
      yeni = job[:log][den..] || []
    end
    yanit_json(res, {
      durum: job[:durum], yeni: yeni, toplam: toplam,
      sayfa: job[:sayfa].to_i, url: job[:site_url]
    })

  elsif req.request_method == 'GET' && yol == '/api/liste'
    yanit_json(res, kopya_listesi)

  elsif req.request_method == 'GET' && yol == '/api/acik'
    klasor = klansor_adi(req.query['kim'])
    if klasor
      system('open', '-R', klasor) unless SUNUCU_MODU
      yanit_json(res, { ok: true })
    else
      yanit_json(res, { hata: 'bulunamadı' }, 404)
    end

  elsif req.request_method == 'GET' && yol == '/api/kaldir'
    kim = req.query['kim'].to_s
    klasor = klansor_adi(kim)
    if klasor
      FileUtils.rm_rf(klasor)
      @kilit.synchronize { @joblar.delete(kim) }
      yanit_json(res, { ok: true })
    else
      yanit_json(res, { hata: 'bulunamadı' }, 404)
    end

  elsif yol.start_with?('/site/')
    kim = yol.sub(%r{\A/site/}, '').split('/').first.to_s
    port = @clone_kilit.synchronize { @clone_sunucular[kim] }
    if port
      # kendi portunda kök dizinden servis ediliyor — yönlendir
      geri = yol.sub(%r{\A/site/#{Regexp.escape(kim)}/?}, '')
      res.status = 302
      res['Location'] = "http://localhost:#{port}/#{geri}"
      res.body = ''
    else
      site_ver(req, res)
    end

  else
    yanit_html(res, '<h1>404</h1><p><a href="/">Panele dön</a></p>', 404)
  end
end

%w[INT TERM].each do |s|
  trap(s) do
    begin
      @clone_sunucu_nesneleri.each_value(&:shutdown)
    rescue StandardError
      nil
    end
    sunucu.shutdown
  end
end

def acik_pencere(port)
  Thread.new do
    sleep 1.2
    system('open', '-a', 'Google Chrome', "http://localhost:#{port}/") ||
      system('open', "http://localhost:#{port}/")
  rescue StandardError
    nil
  end
end

puts
if SUNUCU_MODU
  puts "  sitecopy paneli hazır:  http://0.0.0.0:#{PORT}  (sunucu modu)"
  puts "  Kopyalar: #{KOPYALAR}"
  puts "  Şifre koruması: #{sifre_korumali? ? 'açık' : 'KAPALI (KOPYA_KULLANICI/KOPYA_SIFRE tanımla)'}"
else
  puts "  sitecopy paneli hazır:  http://localhost:#{PORT}"
end
puts "  Durdurmak için: Ctrl+C"

mevcut_kopyalar = kopya_listesi
if mevcut_kopyalar.any?
  puts "  #{mevcut_kopyalar.size} önceki kopya için yerel sunucular başlatılıyor..."
  mevcut_kopyalar.each do |k|
    kok = k[:kok].to_s.empty? ? (URI.join(k[:url], '/').to_s rescue nil) : k[:kok]
    @clone_kilit.synchronize { @clone_kok[k[:kim]] = kok }
    port = clone_sunucu_baslat(k[:kim], File.join(KOPYALAR, k[:kim]), k[:port])
    next unless port && (k[:port] != port || k[:kok].to_s != kok.to_s)
    # sonraki açılışta aynı port kullanılsın diye manifest'i güncelle
    mp = File.join(KOPYALAR, k[:kim], '.kopya.json')
    b = (JSON.parse(File.read(mp)) rescue {}) rescue {}
    b['port'] = port
    b['kok'] = kok
    File.write(mp, JSON.generate(b))
  end
end

acik_pencere(PORT) unless ENV['KOPYA_ACMA'] == '0' || SUNUCU_MODU
sunucu.start
