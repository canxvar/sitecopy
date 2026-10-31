#!/usr/bin/env ruby
# encoding: utf-8
#
# site_kopyala.rb — Web sitesi kopyalama (mirror) aracı
#
# Bir web sitesini tam olarak indirir: HTML sayfaları, CSS, JS, görseller,
# fontlar ve alt sayfalar. Bağlantıları çevrimdışı çalışacak şekilde yeniden
# yazar. Ruby 2.6+ ve Nokogiri gerektirir.
#
#   Kullanım: ruby site_kopyala.rb https://ornek.com [seçenekler]
#   Tüm seçenekler için: ruby site_kopyala.rb --yardim

require 'net/http'
require 'openssl'
require 'uri'
require 'zlib'
require 'stringio'
require 'fileutils'
require 'pathname'
require 'digest'
require 'set'
require 'thread'
require 'optparse'
require 'nokogiri'

# ---------------------------------------------------------------- renkler ---
module Renk
  class << self
    def aktif?
      $stdout.tty? && !SiteKopyala.global_ayar[:sessiz]
    end

    def yesil(s)
      aktif? ? "\e[32m#{s}\e[0m" : s
    end

    def sari(s)
      aktif? ? "\e[33m#{s}\e[0m" : s
    end

    def kirmizi(s)
      aktif? ? "\e[31m#{s}\e[0m" : s
    end

    def mavi(s)
      aktif? ? "\e[34m#{s}\e[0m" : s
    end

    def gri(s)
      aktif? ? "\e[90m#{s}\e[0m" : s
    end
  end
end

# ------------------------------------------------------------ ana sınıf ---
class SiteKopyala
  VARSAYILAN_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
                  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 ' \
                  'Safari/537.36 SiteKopyala/1.0'

  HTML_UZANTILARI = %w[html htm xhtml].freeze

  # Doğrudan sayfa (HTML) olarak sunulabilen uzantılar
  SAYFA_UZANTILARI = (HTML_UZANTILARI + %w[php asp aspx jsp cgi pl]).freeze

  # Dosya olarak indirilecek varlık uzantıları
  VARLIK_UZANTILARI = %w[
    css js mjs map json xml txt rss atom webmanifest
    png jpg jpeg gif webp avif bmp ico svg
    woff woff2 ttf otf eot
    mp4 webm ogv mov mp3 ogg wav m4a flac aac
    pdf zip gz tar rar 7z doc docx xls xlsx ppt pptx
  ].freeze

  # İçerik tipinden uzantı çıkarımı (uzantısız URL'ler için)
  CT_UZANTI = {
    'text/css' => '.css', 'application/javascript' => '.js',
    'text/javascript' => '.js', 'application/x-javascript' => '.js',
    'application/json' => '.json', 'text/json' => '.json',
    'image/png' => '.png', 'image/jpeg' => '.jpg', 'image/gif' => '.gif',
    'image/webp' => '.webp', 'image/avif' => '.avif',
    'image/svg+xml' => '.svg', 'image/x-icon' => '.ico',
    'image/vnd.microsoft.icon' => '.ico', 'image/bmp' => '.bmp',
    'image/tiff' => '.tiff',
    'font/woff2' => '.woff2', 'font/woff' => '.woff',
    'application/font-woff' => '.woff', 'application/font-woff2' => '.woff2',
    'application/x-font-woff' => '.woff',
    'application/x-font-ttf' => '.ttf', 'font/ttf' => '.ttf',
    'font/otf' => '.otf', 'application/x-font-otf' => '.otf',
    'video/mp4' => '.mp4', 'video/webm' => '.webm', 'video/ogg' => '.ogv',
    'audio/mpeg' => '.mp3', 'audio/ogg' => '.ogg', 'audio/wav' => '.wav',
    'audio/mp4' => '.m4a', 'application/pdf' => '.pdf',
    'application/xml' => '.xml', 'text/xml' => '.xml',
    'text/plain' => '.txt', 'application/zip' => '.zip',
    'application/gzip' => '.gz', 'application/octet-stream' => ''
  }.freeze

  # HTML içinde URL taşıyan nitelikler: [CSS seçici, nitelik, tür]
  #   tür: :baglanti (sayfa olabilir) / :varlik / :srcset / :link
  URL_NITELIKLERI = [
    ['a[href]',        'href',        :baglanti],
    ['area[href]',     'href',        :baglanti],
    ['iframe[src]',    'src',         :baglanti],
    ['frame[src]',     'src',         :baglanti],
    ['link[href]',     'href',        :link],
    ['script[src]',    'src',         :varlik],
    ['img[src]',       'src',         :varlik],
    ['img[data-src]',  'data-src',    :varlik],
    ['img[data-original]', 'data-original', :varlik],
    ['img[data-lazy-src]', 'data-lazy-src', :varlik],
    ['img[srcset]',    'srcset',      :srcset],
    ['img[data-srcset]', 'data-srcset', :srcset],
    ['source[src]',    'src',         :varlik],
    ['source[srcset]', 'srcset',      :srcset],
    ['video[src]',     'src',         :varlik],
    ['video[poster]',  'poster',      :varlik],
    ['audio[src]',     'src',         :varlik],
    ['track[src]',     'src',         :varlik],
    ['embed[src]',     'src',         :varlik],
    ['object[data]',   'data',        :varlik],
    ['input[src]',     'src',         :varlik],
    ['meta[property="og:image"]',     'content', :varlik],
    ['meta[property="og:image:url"]', 'content', :varlik],
    ['meta[name="twitter:image"]',    'content', :varlik]
  ].freeze

  ATLANAN_SEMA = %w[data javascript mailto tel about blob sms geo].freeze

  # İndirilemeyen/kalan mutlak adreslerin köprü yollarına çevrileceği
  # nitelikler (bağlantı/a[href] gezinme amaçlı olduğu için bilinçli yok)
  URL_KALAN_SECICILER = [
    ['script[src]', 'src'], ['link[href]', 'href'],
    ['img[src]', 'src'], ['img[data-src]', 'data-src'],
    ['img[srcset]', 'srcset'], ['img[data-srcset]', 'data-srcset'],
    ['source[src]', 'src'], ['source[srcset]', 'srcset'],
    ['video[src]', 'src'], ['video[poster]', 'poster'],
    ['audio[src]', 'src'], ['track[src]', 'src'],
    ['embed[src]', 'src'], ['object[data]', 'data'], ['input[src]', 'src']
  ].freeze

  # Sayfalara eklenen çalışma-anı köprüsü: JS'in çalışma anında kurduğu uzak
  # XHR/fetch/beacon isteklerini VE runtime eklediği script/img/etc.
  # etiketlerini clone sunucusunun _dis/<alan>/<yol> uçlarına yönlendirir.
  # '__KOKHOST__' yer tutucusu kopyalanacak sitenin alan adıyla değişir; JS'in
  # location'dan ürettiği localhost/cdn.localhost adresleri de böylece orijinal
  # alana çevrilir.
  KOPRU_SCRIPT = <<~'JS'
    (function(){
      var KOK='__KOKHOST__';
      function don(u){
        try{
          if(typeof u!=='string')return u;
          if(u.slice(0,2)==='//')u=location.protocol+u;
          if(!/^https?:/i.test(u))return u;
          var t=new URL(u,location.href);
          var h=t.hostname;
          if(t.origin===location.origin||h===KOK)return t.pathname+t.search;
          if(h==='localhost'||h==='127.0.0.1')t.hostname=KOK;
          else if(h.slice(-10)==='.localhost')t.hostname=h.slice(0,-10)+'.'+KOK;
          if(t.origin===location.origin||t.hostname===KOK)return t.pathname+t.search;
          return '/_dis/'+t.host+t.pathname+t.search;
        }catch(e){return u}
      }
      function donS(v){
        return String(v).split(',').map(function(p){
          p=p.trim(); if(!p)return p;
          var b=p.split(/\s+/); b.unshift(don(b.shift())); return b.join(' ');
        }).join(', ');
      }
      var ac=XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open=function(m,u){return ac.call(this,m,don(u))};
      if(window.fetch){
        var fk=window.fetch;
        window.fetch=function(u,i){
          if(typeof u==='string')u=don(u);
          else if(u&&typeof u.url==='string'&&/^https?:/i.test(u.url))u=new Request(don(u.url),u);
          return fk.call(this,u,i);
        };
      }
      if(navigator.sendBeacon){
        var sb=navigator.sendBeacon.bind(navigator);
        navigator.sendBeacon=function(u,d){return sb(don(String(u)),d)};
      }
      // runtime eklenen etiketler: src/href set edilirken anında yeniden yaz
      function muhur(P,n,f){
        try{
          var d=Object.getOwnPropertyDescriptor(P,n);
          if(!d||!d.set)return;
          Object.defineProperty(P,n,{get:d.get,set:function(v){d.set.call(this,f(String(v)))},
            configurable:true,enumerable:d.enumerable});
        }catch(e){}
      }
      var W=window;
      if(W.HTMLImageElement){muhur(W.HTMLImageElement.prototype,'src',don);muhur(W.HTMLImageElement.prototype,'srcset',donS)}
      if(W.HTMLScriptElement)muhur(W.HTMLScriptElement.prototype,'src',don);
      if(W.HTMLIFrameElement)muhur(W.HTMLIFrameElement.prototype,'src',don);
      if(W.HTMLLinkElement)muhur(W.HTMLLinkElement.prototype,'href',don);
      if(W.HTMLSourceElement){muhur(W.HTMLSourceElement.prototype,'src',don);muhur(W.HTMLSourceElement.prototype,'srcset',donS)}
      if(W.HTMLVideoElement){muhur(W.HTMLVideoElement.prototype,'src',don);muhur(W.HTMLVideoElement.prototype,'poster',don)}
      if(W.HTMLAudioElement)muhur(W.HTMLAudioElement.prototype,'src',don);
      if(W.HTMLEmbedElement)muhur(W.HTMLEmbedElement.prototype,'src',don);
      if(W.HTMLInputElement)muhur(W.HTMLInputElement.prototype,'src',don);
      if(W.HTMLTrackElement)muhur(W.HTMLTrackElement.prototype,'src',don);
      if(W.HTMLObjectElement)muhur(W.HTMLObjectElement.prototype,'data',don);
      // innerHTML vb. ile eklenenler için emniyet ağı (döngü yok: yazılan
      // göreli kalınca yeniden işlem yapılmaz)
      if(W.MutationObserver&&document.documentElement){
        var SEC=['src','srcset','href','poster','data'];
        var ET={SCRIPT:1,IMG:1,IFRAME:1,LINK:1,SOURCE:1,VIDEO:1,AUDIO:1,EMBED:1,OBJECT:1,INPUT:1,TRACK:1};
        var go=function(n){
          if(!n||n.nodeType!==1||!ET[n.tagName])return;
          SEC.forEach(function(a){
            var v=n.getAttribute&&n.getAttribute(a);
            if(v&&/^(?:\/\/|https?:)/i.test(v))n.setAttribute(a,a==='srcset'?donS(v):don(v));
          });
        };
        try{
          new MutationObserver(function(list){
            list.forEach(function(k){
              if(k.type==='attributes'){go(k.target);return}
              Array.prototype.forEach.call(k.addedNodes,go);
            });
          }).observe(document.documentElement,{childList:true,subtree:true,
            attributes:true,attributeFilter:SEC});
        }catch(e){}
      }
    })();
  JS

  CSS_URL_RE = /url\(\s*(['"]?)([^'")]+)\1\s*\)/i
  CSS_IMPORT_RE = /@import\s+(?:url\(\s*)?['"]?([^'"\)\s]+)['"]?\s*\)?/i

  @@global_ayar = { sessiz: false }

  def self.global_ayar
    @@global_ayar
  end

  def self.global_ayar=(a)
    @@global_ayar = a
  end

  # ---------------------------------------------------------- başlatma ---
  def initialize(hedef, ayar)
    @ayar = ayar
    @@global_ayar = ayar
    @kok = normallestir(hedef)
    raise "Geçersiz hedef URL: #{hedef.inspect}" unless @kok
    @kok_host = URI.parse(@kok).host.downcase
    @gorulen = Set.new            # kuyruğa alınmış sayfa URL'leri
    @haritalar = {}               # URL -> disk yolu (kök dizine göreli)
    @yol_sahibi = {}              # disk yolu -> URL (çakışma önlemek için)
    @sayfalar = []                # { url:, ham: }
    @css_dosyalari = []           # { url:, yol:, ham: }
    @varliklar = Set.new          # indirilecek varlık URL'leri
    @islenen_varliklar = Set.new
    @hatalar = []
    @uyarilar = []
    @kilit = Mutex.new
    @son_zaman = {}
    @zorunlu_aralik = {} # 429 sonrası büyüyen zorunlu bekleme (sn)
    @sayaclar = { sayfa: 0, varlik: 0, css: 0, bayt: 0 }
    @baslangic = Time.now
    @robots_gruplari = nil
  end

  # ------------------------------------------------------------- HTTP ---
  # [govde, icerik_tipi, son_url] döner; başarısızsa nil
  def indir(url, sayfa_mi = false)
    uri = URI.parse(url)
    yondenme = 8
    while yondenme > 0
      yondenme -= 1
      bekle(uri.host)
      begin
        sonuc = tek_istek(uri, sayfa_mi)
        if sonuc.is_a?(Array)
          if sonuc[0] == :yondenme
            uri = sonuc[1] # yönlendirmeyi takip et
            next
          end
          return sonuc # başarı: [govde, icerik_tipi, son_url]
        end
        return nil if sonuc == :son # 4xx vb. — deneme yok
        # 429/503: sunucu yoğun — giderek artan beklemeyle tekrar dene
        sleep [2.0 * (9 - yondenme), 10].min if sonuc == :yeniden && yondenme > 0
      rescue Timeout::Error, SocketError, Errno::ECONNREFUSED,
             Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
             OpenSSL::SSL::SSLError, EOFError, Net::HTTPBadResponse,
             Net::OpenTimeout, Net::ReadTimeout, IOError, ArgumentError
        return nil if yondenme.zero?
      end
      sleep 0.6
    end
    nil
  end

  def tek_istek(uri, sayfa_mi)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = @ayar[:zaman_asimi]
    http.read_timeout = @ayar[:zaman_asimi]
    if uri.scheme == 'https'
      http.use_ssl = true
      http.verify_mode = @ayar[:ssl_dogrula] ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    end
    istek = Net::HTTP::Get.new(uri.request_uri.to_s.empty? ? '/' : uri.request_uri)
    istek['User-Agent'] = @ayar[:ua]
    istek['Accept-Encoding'] = 'gzip, deflate'
    istek['Accept'] = sayfa_mi ? 'text/html,application/xhtml+xml,*/*;q=0.8' : '*/*'
    istek['Accept-Language'] = 'tr,tr-TR;q=0.9,en;q=0.8,*;q=0.5'
    if uri.user && uri.password
      istek.basic_auth(URI::DEFAULT_PARSER.unescape(uri.user),
                       URI::DEFAULT_PARSER.unescape(uri.password))
    end

    yanit = nil
    http.request(istek) { |y| yanit = y }

    case yanit
    when Net::HTTPRedirection
      konum = yanit['location'].to_s.strip
      return :son if konum.empty?
      begin
        yeni = URI.join(uri.to_s, konum)
      rescue StandardError
        return :son
      end
      yeni.fragment = nil
      [:yondenme, yeni]
    when Net::HTTPTooManyRequests, Net::HTTPServiceUnavailable, Net::HTTPGatewayTimeout
      # sunucu hız sınırı uyguluyor — o alan adı için bekleme süresini büyüt
      @kilit.synchronize do
        mevcut = @zorunlu_aralik[uri.host] || @ayar[:hiz]
        @zorunlu_aralik[uri.host] = [[mevcut * 2, 8.0].min, 0.5].max
        @son_zaman[uri.host] = Time.now + @zorunlu_aralik[uri.host]
      end
      :yeniden
    when Net::HTTPSuccess
      @kilit.synchronize do
        z = @zorunlu_aralik[uri.host]
        @zorunlu_aralik[uri.host] = z / 2 if z && z > 0.6
      end
      [govde_coz(yanit), icerik_tipi(yanit), uri.to_s]
    else
      :son
    end
  end

  def govde_coz(yanit)
    b = yanit.body.to_s.dup.force_encoding(Encoding::BINARY)
    case yanit['content-encoding'].to_s.downcase
    when 'gzip', 'x-gzip'
      b = (Zlib::GzipReader.new(StringIO.new(b)).read rescue b)
    when 'deflate'
      b = (Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(b) rescue
           (Zlib::Inflate.inflate(b) rescue b))
    end
    b
  end

  def icerik_tipi(yanit)
    yanit['content-type'].to_s.split(';').first.to_s.strip.downcase
  end

  # İstemci kibarlığı: alan adı başına istekler arası bekleme.
  # Uyku MUTEX DIŞINDA yapılır: 429 backoff'u uzun bekleme süreleri
  # ürettiği için kilit içinde uyumak tüm iş parçacıklarını donduruyordu.
  # Slot rezervasyonuyla istekler aralığa uygun serilenir.
  def bekle(host)
    zorunlu = @kilit.synchronize { @zorunlu_aralik[host] }
    aralik = [@ayar[:hiz], zorunlu.to_f].max
    return if aralik <= 0
    planlanan = nil
    @kilit.synchronize do
      son = @son_zaman[host] || Time.now
      planlanan = [son, Time.now].max
      @son_zaman[host] = planlanan + aralik
    end
    bekleme = planlanan - Time.now
    sleep(bekleme) if bekleme > 0
  end

  # ------------------------------------------------------ URL işlemleri ---
  def normallestir(url, taban = nil)
    ham = url.to_s.strip
    return nil if ham.empty?
    u = nil
    begin
      u = taban ? URI.join(taban, ham) : URI.parse(ham)
    rescue URI::InvalidURIError
      begin
        duzeltilmis = URI::DEFAULT_PARSER.escape(ham)
        u = taban ? URI.join(taban, duzeltilmis) : URI.parse(duzeltilmis)
      rescue URI::InvalidURIError
        return nil
      end
    end
    return nil unless u.is_a?(URI::HTTP) || u.is_a?(URI::HTTPS)
    return nil if ATLANAN_SEMA.include?(u.scheme.downcase)
    return nil unless u.host && !u.host.empty?
    u.fragment = nil
    u.scheme = u.scheme.downcase
    u.host = u.host.downcase
    u.port = nil if (u.scheme == 'http' && u.port == 80) ||
                    (u.scheme == 'https' && u.port == 443)
    u.to_s
  end

  def anasayfa?(url)
    URI.parse(url).host.to_s.downcase == @kok_host
  rescue StandardError
    false
  end

  def varlik_mi?(url)
    ext = File.extname(URI.parse(url).path.to_s).downcase.delete('.')
    !ext.empty? && VARLIK_UZANTILARI.include?(ext)
  end

  def sayfa_html_mi?(icerik_tipi, url)
    return true if icerik_tipi.include?('html')
    return false unless icerik_tipi.empty?
    ext = File.extname(URI.parse(url).path.to_s).downcase.delete('.')
    ext.empty? || SAYFA_UZANTILARI.include?(ext)
  end

  # ------------------------------------------------------- disk yolları ---
  # tur: :sayfa veya :varlik ; uzanti_ipucu içerik tipinden gelen uzantı
  def yerel_yol(url, tur, uzanti_ipucu = nil)
    @kilit.synchronize do
      return @haritalar[url] if @haritalar.key?(url)
      u = URI.parse(url)
      parcalar = u.path.to_s.split('/')
                 .reject { |p| p.empty? || p == '.' || p == '..' }
                 .map { |p| parca_temizle(URI::DEFAULT_PARSER.unescape(p)) }
      sorgu = u.query.to_s
      parcalar = ['_dis', u.host.to_s.downcase] + parcalar if u.host.to_s.downcase != @kok_host

      if tur == :sayfa
        sorgu_suf = sorgu.empty? ? '' : '_' + Digest::MD5.hexdigest(sorgu)[0, 6]
        son = parcalar.last.to_s
        nokta = son.rindex('.')
        uzanti = nokta ? son[(nokta + 1)..-1].downcase : ''
        if parcalar.empty?
          parcalar = ['index' + sorgu_suf + '.html']
        elsif HTML_UZANTILARI.include?(uzanti)
          parcalar[-1] = son + sorgu_suf
        elsif nokta
          # .php/.aspx vb. sayfalar tarayıcıda açılsın diye .html'e çevrilir
          parcalar[-1] = son[0...nokta] + sorgu_suf + '.html'
        else
          parcalar << ('index' + sorgu_suf + '.html')
        end
      else
        if parcalar.empty?
          parcalar = ['index' + (uzanti_ipucu.to_s.empty? ? '' : uzanti_ipucu)]
        elsif File.extname(parcalar.last).empty? && uzanti_ipucu && !uzanti_ipucu.empty?
          parcalar[-1] = parcalar[-1] + uzanti_ipucu
        end
      end

      yol = catisma_onle(parcalar.join('/'), url)
      @haritalar[url] = yol
    end
  end

  def parca_temizle(p)
    p = p.gsub(/[\\\/\:\*\?\"\<\>\|\x00-\x1f]/, '_')
    p = p.gsub(/\A\.+/, '_')
    p.empty? ? '_' : p
  end

  def catisma_onle(yol, url)
    if (mevcut = @yol_sahibi[yol]) && mevcut != url
      uz = File.extname(yol)
      alt = File.basename(yol, uz)
      kisa = Digest::MD5.hexdigest(url)[0, 6]
      klasor = File.dirname(yol)
      yol = klasor == '.' ? "#{alt}_#{kisa}#{uz}" : "#{klasor}/#{alt}_#{kisa}#{uz}"
    end
    @yol_sahibi[yol] = url
    yol
  end

  # kaynak dosyadan hedef dosyaya göreli bağlantı
  def goreli(kaynak, hedef)
    a = Pathname.new(File.dirname(kaynak.to_s))
    b = Pathname.new(hedef.to_s)
    b.relative_path_from(a).to_s
  rescue StandardError
    hedef.to_s
  end

  # Kopyalanmış bir URL'i göreli yerel bağlantıya çevirir.
  # Kopyalanmamışsa orijinal URL olduğu gibi bırakılır (çevrimiçi çalışır).
  def baglanti_yaz(kaynak_dosya, hedef_url)
    hedef_yol = @haritalar[hedef_url]
    return hedef_url unless hedef_yol
    y = goreli(kaynak_dosya, hedef_yol)
    y.gsub(' ', '%20').gsub('"', '%22')
  end

  # --------------------------------------------------------- ana akış ---
  def kopyala
    bilgi "#{Renk.mavi('Hedef:')} #{@kok}"
    bilgi "#{Renk.mavi('Çıktı:')} #{@ayar[:cikti]}"
    bilgi Renk.gri("Derinlik #{@ayar[:derinlik]}, #{@ayar[:is]} iş parçacığı, " \
                   "sayfa limiti #{@ayar[:sayfa_limit]}, " \
                   "varlık limiti #{@ayar[:varlik_limit]}")
    bilgi ''

    sayfalari_tara
    varliklari_indir
    bicimle_ve_yaz
    tohum_kok_yaz
    rapor_yaz
    ozet
  end

  # -------------------------------------------------- 1) sayfa taraması ---
  def sayfalari_tara
    @gorulen << @kok
    kuyruk = [[@kok, 0]]
    until kuyruk.empty?
      seviye = kuyruk
      kuyruk = []
      paralel(seviye) do |url, derinlik|
        sayfayi_isle(url, derinlik) do |yeni_url, yeni_derinlik|
          @kilit.synchronize { kuyruk << [yeni_url, yeni_derinlik] }
        end
      end
    end
  end

  def sayfayi_isle(url, derinlik)
    sonuc = indir(url, true)
    unless sonuc
      @kilit.synchronize { @hatalar << "Sayfa alınamadı: #{url}" }
      return
    end
    govde, ct, son_url = sonuc

    unless sayfa_html_mi?(ct, son_url)
      # a[href] bir PDF/görsel vb. çıktıysa varlık olarak kaydet
      @kilit.synchronize do
        @varliklar << son_url
        @varliklar << url if url != son_url
      end
      return
    end

    yol = yerel_yol(son_url, :sayfa)
    @kilit.synchronize do
      @haritalar[url] ||= yol
      @sayfalar << { url: son_url, ham: govde }
      @sayaclar[:sayfa] += 1
      @sayaclar[:bayt] += govde.bytesize
      no = @sayaclar[:sayfa]
      sira = @ayar[:sessiz] ? '' : Renk.gri("[#{no}] ")
      puts "  #{Renk.yesil('✓')} #{sira}#{son_url} #{Renk.gri('→')} #{yol} " \
           "#{Renk.gri("(#{boyut(govde.bytesize)})")}" unless @ayar[:sessiz]
    end

    sayfa_baglantilari(son_url, govde, derinlik) do |yeni_url, yeni_derinlik|
      yield yeni_url, yeni_derinlik
    end
  end

  # HTML'i çözüp sayfa adaylarını kuyruğa, varlıkları listeye alır
  def sayfa_baglantilari(sayfa_url, govde, derinlik)
    doc = Nokogiri::HTML(govde)
    taban = sayfa_url
    base = doc.at('base[href]')
    if base
      cozulmus = normallestir(base['href'], sayfa_url)
      taban = cozulmus if cozulmus
    end

    URL_NITELIKLERI.each do |secici, nitelik, tur|
      doc.css(secici).each do |el|
        deger = el[nitelik].to_s
        next if deger.strip.empty?
        if tur == :srcset
          srcset_urlleri(deger, taban).each { |u| varliga_al(u) }
        else
          hedef = normallestir(deger, taban)
          next unless hedef
          case tur
          when :baglanti
            varlik_mi?(hedef) ? varliga_al(hedef) : sayfa_aday(hedef, derinlik) { |u, d| yield u, d }
          when :link
            rel = el['rel'].to_s.downcase
            if rel.split(/\s+/).include?('alternate') && el['type'].to_s.include?('html')
              anasayfa?(hedef) ? sayfa_aday(hedef, derinlik) { |u, d| yield u, d } : varliga_al(hedef)
            else
              varliga_al(hedef)
            end
          else
            varliga_al(hedef)
          end
        end
      end
    end

    # satır içi stiller ve <style> bloklarındaki url()/@import
    doc.css('[style]').each do |el|
      css_urlleri(el['style'].to_s, taban).each { |u| varliga_al(u) }
    end
    doc.css('style').each do |el|
      css_urlleri(el.content.to_s, taban).each { |u| varliga_al(u) }
    end
  end

  def sayfa_aday(url, derinlik)
    return if @ayar[:robots] && robots_yasakli?(url)
    unless anasayfa?(url) || @ayar[:harici_sayfa]
      # diğer alan adları sayfa olarak kopyalanmaz
      return
    end
    ekleme_yapabilir = @kilit.synchronize do
      if @gorulen.size >= @ayar[:sayfa_limit]
        unless @sayfa_limit_uyarildi
          @sayfa_limit_uyarildi = true
          @uyarilar << "Sayfa limiti doldu (#{@ayar[:sayfa_limit]}); tarama sınırlandırıldı."
        end
        false
      elsif @gorulen.include?(url)
        false
      else
        @gorulen << url
        true
      end
    end
    return unless ekleme_yapabilir
    return if derinlik + 1 > @ayar[:derinlik]
    yield url, derinlik + 1
  end

  # Bilinen izleyici/reklam alanları — çevrimdışı kopyaya hiç alınmaz,
  # etiketleri HTML'den temizlenir
  IZLEYICILER = %w[
    platform-api.sharethis.com platform-t.sharethis.com sharethis.com
    google-analytics.com googletagmanager.com googleadservices.com
    googlesyndication.com doubleclick.net
    connect.facebook.net facebook.com
    hotjar.com mixpanel.com segment.com segment.io amplitude.com
    bugsnag.com sentry.io newrelic.com nr-data.net
    criteo.com adsrvr.org taboola.com outbrain.com
    adnxs.com pubmatic.com openx.net casalemedia.com rubiconproject.com
    scorecardresearch.com quantserve.com
    adservice.google.com
    stripe.com
    realtimely.io
    klaviyo.com mailchimp.com list-manage.com
    cdn.cookielaw.org cookiebot.com onetrust.com privacymanager.io trustarc.com
    yandex.ru mc.yandex.ru
  ].freeze

  def izleyici?(url)
    host = begin
      URI.parse(url).host.to_s.downcase
    rescue StandardError
      ''
    end
    return false if host.empty?
    IZLEYICILER.any? { |d| host == d || host.end_with?(".#{d}") }
  end

  def varliga_al(url)
    return if izleyici?(url) # çevrimdışı kopyaya gereksiz, yalnızca gürültü
    return if @ayar[:sadece_kendi] && !anasayfa?(url)
    @kilit.synchronize { @varliklar << url }
  end

  # ------------------------------------------------- 2) varlık indirme ---
  def varliklari_indir
    dalgalar = 0
    loop do
      beklenecek = @kilit.synchronize do
        @varliklar.reject { |u| @islenen_varliklar.include?(u) }
                  .each { |u| @islenen_varliklar << u }
      end
      break if beklenecek.empty?
      dalgalar += 1
      if dalgalar > 80
        @kilit.synchronize { @uyarilar << 'Varlık dalgaları sınırına ulaşıldı; tarama durduruldu.' }
        break
      end
      paralel(beklenecek) { |u| varligi_indir(u) }
    end
  end

  def varligi_indir(url)
    if @kilit.synchronize { @sayaclar[:varlik] + @sayaclar[:css] } >= @ayar[:varlik_limit]
      @kilit.synchronize do
        unless @varlik_limit_uyarildi
          @varlik_limit_uyarildi = true
          @uyarilar << "Varlık limiti doldu (#{@ayar[:varlik_limit]}); kalan varlıklar atlandı."
        end
      end
      return
    end

    sonuc = indir(url, false)
    unless sonuc
      @kilit.synchronize { @hatalar << "Varlık alınamadı: #{url}" }
      return
    end
    govde, ct, son_url = sonuc

    # sunucu başka bir yere yönlendirdiyse nihai URL'i de eşle
    if son_url != url
      yol0 = yerel_yol(son_url, :varlik, uzantı_ver(ct, son_url))
      @kilit.synchronize { @haritalar[url] ||= yol0 }
      url = son_url
    end

    uzanti = uzantı_ver(ct, url)
    yol = yerel_yol(url, :varlik, uzanti)

    # en fazla izin verilen boyut
    maks = @ayar[:maks_mb] * 1024 * 1024
    if govde.bytesize > maks
      @kilit.synchronize do
        @haritalar.delete(url)
        @hatalar << "Boyut sınırını aştı, atlandı (#{boyut(govde.bytesize)}): #{url}"
      end
      return
    end

    if ct == 'text/css'
      @kilit.synchronize do
        @css_dosyalari << { url: url, yol: yol, ham: govde }
        @sayaclar[:css] += 1
        @sayaclar[:bayt] += govde.bytesize
      end
      # CSS içindeki url()/@import yeni varlıklar getirebilir
      css_urlleri(metin_olarak(govde), url).each { |u| varliga_al(u) }
    else
      disk_yaz(yol, govde)
      @kilit.synchronize do
        @sayaclar[:varlik] += 1
        @sayaclar[:bayt] += govde.bytesize
      end
      # JS bundle'larındaki görsel/varlık literallerini de indir
      uz = File.extname(URI.parse(url).path.to_s).downcase
      js_varlik_topla(govde, url) if uz == '.js' || uz == '.mjs'
      puts "    #{Renk.gri('·')} #{url} #{Renk.gri('→')} #{yol} " \
           "#{Renk.gri("(#{boyut(govde.bytesize)})")}" if @ayar[:acik]
    end
  end

  def uzantı_ver(ct, url)
    ext = File.extname(URI.parse(url).path.to_s)
    return ext unless ext.empty?
    CT_UZANTI[ct].to_s
  end

  # JS bundle'ları içindeki görsel/varlık literallerini toplar.
  # Mutlak (/images/x.png) ve göreli (brand/logo.png) yollar taranır;
  # kopya kendi kök dizininden servis edildiği için yeniden yazma gerekmez.
  JS_VARLIK_RE = /["'`]([A-Za-z0-9_@%+.,~\/-]+\.(?:png|jpe?g|webp|avif|gif|svg|ico|woff2?|ttf|otf|eot|mp4|webm|mp3|ogg|pdf)(?:\?[^"'`\s]*)?)["'`]/i

  def js_varlik_topla(govde, js_url)
    sayac = 0
    govde.to_s.scan(JS_VARLIK_RE) do
      sayac += 1
      break if sayac > 400 # dosya başına tavan
      hedef = normallestir(Regexp.last_match(1), js_url)
      varliga_al(hedef) if hedef
    end
  rescue StandardError
    nil
  end

  # ------------------------------------------- 3) yeniden yazma ve kayıt ---
  def bicimle_ve_yaz
    bilgi ''
    bilgi Renk.mavi('Bağlantılar yeniden yazılıyor...')

    @css_dosyalari.each do |c|
      metin = css_bicimle(metin_olarak(c[:ham]), c[:url], c[:yol])
      disk_yaz(c[:yol], metin)
    end

    @sayfalar.each do |s|
      yol = @haritalar[s[:url]]
      next unless yol
      doc = Nokogiri::HTML(s[:ham])
      html_bicimle(doc, s[:url])
      disk_yaz(yol, html_cikti(doc))
    end
  end

  def html_bicimle(doc, sayfa_url)
    taban = sayfa_url
    base = doc.at('base[href]')
    if base
      cozulmus = normallestir(base['href'], sayfa_url)
      taban = cozulmus if cozulmus
      base.remove
    end

    # çevrimdışı yüklemeyi engelleyen etiketleri temizle
    doc.css('meta[http-equiv]').each do |m|
      ee = m['http-equiv'].to_s.downcase
      m.remove if ee == 'content-security-policy' || ee == 'content-security-policy-report-only'
    end
    doc.css('[integrity]').each { |el| el.remove_attribute('integrity') }

    # izleyici/reklam etiketlerini temizle (çevrimdışı anlamsız, sessizce
    # dışarı açılmayı da engeller)
    %w[script img iframe embed].each do |etiket|
      doc.css(etiket).each do |el|
        kaynak = el['src'].to_s
        el.remove if !kaynak.empty? && izleyici?(kaynak)
      end
    end
    doc.css('link[href]').each do |el|
      el.remove if izleyici?(el['href'].to_s)
    end

    # çalışma-anı köprüsünü head'in başına ekle: JS'in çalışma anında kurduğu
    # uzak XHR/fetch/beacon istekleri ve runtime eklenen etiketler clone
    # sunucusuna yönlensin
    bas = doc.at('head')
    if bas && bas.at_xpath('./script[@data-kopru]').nil?
      kopru = Nokogiri::XML::Node.new('script', doc)
      kopru['data-kopru'] = '1'
      kopru.content = KOPRU_SCRIPT.gsub('__KOKHOST__', @kok_host.to_s)
      ilk = bas.element_children.first
      ilk ? ilk.add_previous_sibling(kopru) : bas.add_child(kopru)
    end

    # UTF-8 bilgisini güncelle (dosya UTF-8 olarak kaydediliyor)
    doc.css('meta[charset]').each { |m| m['charset'] = 'UTF-8' }
    doc.css('meta[http-equiv]').each do |m|
      next unless m['http-equiv'].to_s.downcase == 'content-type'
      m['content'] = m['content'].to_s.sub(/charset=[^;"']+/i, 'charset=UTF-8')
    end

    URL_NITELIKLERI.each do |secici, nitelik, tur|
      doc.css(secici).each do |el|
        deger = el[nitelik].to_s
        next if deger.strip.empty?
        if tur == :srcset
          yeni = srcset_bicimle(deger, taban, el)
          el[nitelik] = yeni if yeni && yeni != deger
        else
          yeni = tek_baglanti(deger, taban, tur, el)
          el[nitelik] = yeni if yeni && yeni != deger
        end
      end
    end

    # indirilemeyen kalan mutlak adresleri de köprü yollarına çevir — ilk
    # görüntülemede sunucu orijinal host'tan yakalar (kendini onarır) ve
    # sayfa hiçbir zaman dışarı istek atmaz
    kaynak_dosya = @haritalar[sayfa_url] || 'index.html'
    URL_KALAN_SECICILER.each do |secici, nitelik|
      doc.css(secici).each do |el|
        deger = el[nitelik].to_s.strip
        next if deger.empty? || deger.start_with?('#') || deger =~ /\Adata:/i
        yeni = if nitelik == 'srcset'
                 srcset_kopru(deger, kaynak_dosya, taban)
               else
                 kopru_baglanti(deger, taban, kaynak_dosya)
               end
        el[nitelik] = yeni if yeni && yeni != deger
      end
    end

    doc.css('[style]').each do |el|
      el['style'] = css_bicimle(el['style'].to_s, taban, @haritalar[sayfa_url])
    end
    doc.css('style').each do |el|
      el.content = css_bicimle(el.content.to_s, taban, @haritalar[sayfa_url])
    end
  end

  # tek bir HTML niteliği için yeni değer (nil = değiştirme)
  def tek_baglanti(deger, taban, tur, el)
    return nil if deger.strip.start_with?('#')
    hedef = normallestir(deger, taban)
    return nil unless hedef
    if tur == :link
      rel = el['rel'].to_s.downcase.split(/\s+/)
      if rel.include?('alternate') && el['type'].to_s.include?('html')
        return nil unless @haritalar[hedef]
      end
    end
    return nil unless @haritalar[hedef]
    baglanti_yaz(@haritalar[taban] || 'index.html', hedef)
  end

  def srcset_bicimle(deger, taban, el)
    kaynak_dosya = @haritalar[taban] || 'index.html'
    parcalar = deger.split(',')
    yeni = parcalar.map do |p|
      p2 = p.strip
      next p2 if p2.empty?
      parca = p2.split(/\s+/)
      ilk = parca.shift.to_s
      if ilk =~ /\Adata:/i
        p2
      else
        hedef = normallestir(ilk, taban)
        if hedef && @haritalar[hedef]
          ([baglanti_yaz(kaynak_dosya, hedef)] + parca).join(' ')
        else
          p2
        end
      end
    end
    yeni.join(', ')
  end

  # --------------------------------------------------- köprü yardımcıları ---
  # Mutlak uzak adresi clone sunucusu yoluyla göreli bağlantıya çevirir.
  # Aynı host → sayfanın kendi yolu; yabancı host → _dis/<host>/<yol>.
  def kopru_baglanti(deger, taban_url, kaynak_dosya)
    return nil unless deger =~ %r{\A(?:https?:)?//}i # yalnızca mutlak adresler
    hedef = normallestir(deger, taban_url)
    return nil unless hedef
    u = URI.parse(hedef) rescue nil
    return nil unless u.is_a?(URI::HTTP) && u.host && !u.host.empty?
    host = u.host.to_s.downcase
    parcalar = u.path.to_s.split('/')
               .reject { |p| p.empty? || p == '.' || p == '..' }
               .map { |p| parca_temizle(URI::DEFAULT_PARSER.unescape(p)) }
    if host == @kok_host
      return nil if parcalar.empty? # kök sayfa — dokunma
      yol = parcalar.join('/')
    else
      parcalar = ['_kaynak'] if parcalar.empty?
      yol = (['_dis', host] + parcalar).join('/')
    end
    sorgu = u.query.to_s.empty? ? '' : "?#{u.query}"
    goreli(kaynak_dosya, yol) + sorgu
  end

  # srcset içindeki indirilememiş mutlak adresleri köprü yollarına çevirir
  def srcset_kopru(deger, kaynak_dosya, taban_url)
    yeni = deger.split(',').map do |p|
      p2 = p.strip
      next p2 if p2.empty?
      parca = p2.split(/\s+/)
      ilk = parca.shift.to_s
      if ilk =~ /\Adata:/i
        p2
      else
        k = kopru_baglanti(ilk, taban_url, kaynak_dosya)
        k ? ([k] + parca).join(' ') : p2
      end
    end
    yeni.join(', ')
  end

  # CSS metnindeki url()/@import adreslerini yerel yollara çevirir
  def css_bicimle(metin, taban_url, dosya_yolu)
    return metin if metin.nil? || metin.empty?
    kaynak = dosya_yolu || @haritalar[taban_url] || 'index.html'

    metin = metin.gsub(CSS_IMPORT_RE) do
      tam = Regexp.last_match(0)
      hammadde = Regexp.last_match(1)
      if hammadde =~ /\Adata:/i
        tam
      else
        hedef = normallestir(hammadde, taban_url)
        if hedef && @haritalar[hedef]
          "@import \"#{baglanti_yaz(kaynak, hedef)}\""
        else
          tam
        end
      end
    end

    metin.gsub(CSS_URL_RE) do
      tam = Regexp.last_match(0)
      tirnak = Regexp.last_match(1)
      hammadde = Regexp.last_match(2).to_s.strip
      if hammadde.empty? || hammadde.start_with?('#') || hammadde =~ /\Adata:/i
        tam
      else
        hedef = normallestir(hammadde, taban_url)
        if hedef && @haritalar[hedef]
          "url(#{tirnak}#{baglanti_yaz(kaynak, hedef)}#{tirnak})"
        else
          tam
        end
      end
    end
  end

  # ------------------------------------------------------ robots.txt ---
  def robots_yasakli?(url)
    gruplari_yukle
    return false if @robots_gruplari.empty?
    yol = URI.parse(url).path.to_s
    token = @ayar[:ua].split('/').first.to_s.split(' ').first.to_s.downcase
    yasaklar = []
    @robots_gruplari.each do |g|
      ua = g[:ua].downcase
      next unless ua == '*' || (token && !token.empty? && ua.include?(token))
      yasaklar.concat(g[:yasaklar])
    end
    yasaklar.any? { |y| !y.empty? && yol.start_with?(y) }
  end

  def gruplari_yukle
    return if @robots_gruplari
    @robots_gruplari = []
    sonuc = indir(URI.join(@kok, '/robots.txt').to_s, false)
    return unless sonuc
    satirlar = metin_olarak(sonuc[0]).split(/\r?\n/)
    mevcut = nil
    satirlar.each do |satir|
      satir = satir.sub(/#.*\z/, '').strip
      next if satir.empty?
      if satir =~ /\Auser-agent\s*:\s*(.+)\z/i
        ua = Regexp.last_match(1).strip
        if mevcut && mevcut[:son_ua]
          # ardışık user-agent satırları aynı gruptur
          mevcut[:ua_listesi] << ua
        else
          mevcut = { ua_listesi: [ua], yasaklar: [], son_ua: true }
          @robots_gruplari << mevcut
        end
      elsif satir =~ /\A(disallow|allow)\s*:\s*(.*)\z/i
        mevcut ||= { ua_listesi: ['*'], yasaklar: [], son_ua: false }
        mevcut[:son_ua] = false
        if Regexp.last_match(1).downcase == 'disallow'
          y = Regexp.last_match(2).strip
          mevcut[:yasaklar] << y unless y.empty?
        end
      elsif satir =~ /\A(sitemap|crawl-delay|host)\s*:/i
        mevcut[:son_ua] = false if mevcut
      end
    end
    # birden fazla UA satırı olan grupları genişlet
    genis = []
    @robots_gruplari.each do |g|
      g[:ua_listesi].each { |ua| genis << { ua: ua, yasaklar: g[:yasaklar] } }
    end
    @robots_gruplari = genis
  rescue StandardError
    @robots_gruplari = []
  end

  # Tohum URL kök dizin dışındaysa (ör. /tr/sayfa-440) kök index.html hiç
  # yazılmaz; panel ve çift tıklama için basit bir yönlendirme sayfası yazar.
  def tohum_kok_yaz
    return if File.file?(File.join(@ayar[:cikti], 'index.html'))
    hedef = @haritalar[@kok]
    return if hedef.nil? || hedef == 'index.html'
    icerik = "<!DOCTYPE html>\n<html lang=\"tr\"><head><meta charset=\"utf-8\">\n" \
             "<meta http-equiv=\"refresh\" content=\"0; url=#{hedef}\">\n" \
             "<title>Yönlendiriliyor…</title>\n" \
             "<script>location.replace(#{hedef.inspect})</script></head>\n" \
             "<body style=\"font-family:system-ui;text-align:center;padding:3rem\">" \
             "<p><a href=\"#{hedef}\">Sayfaya git</a></p></body></html>\n"
    disk_yaz('index.html', icerik)
  rescue StandardError
    nil
  end

  # ------------------------------------------------------- rapor/özet ---
  def rapor_yaz
    sure = Time.now - @baslangic
    klasor = @ayar[:cikti]
    FileUtils.mkdir_p(klasor)
    satirlar = []
    satirlar << 'Site Kopyalama Raporu'
    satirlar << '=' * 50
    satirlar << "Hedef:      #{@kok}"
    satirlar << "Tarih:      #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    satirlar << format('Süre:       %.1f sn', sure)
    satirlar << "Sayfa:      #{@sayaclar[:sayfa]}"
    satirlar << "CSS dosyası: #{@sayaclar[:css]}"
    satirlar << "Varlık:     #{@sayaclar[:varlik]}"
    satirlar << "Toplam:     #{boyut(@sayaclar[:bayt])}"
    satirlar << ''
    satirlar << 'Kopyalanan sayfalar:'
    @sayfalar.each { |s| satirlar << "  #{@haritalar[s[:url]]}  <-  #{s[:url]}" }
    unless @uyarilar.empty?
      satirlar << ''
      satirlar << 'Uyarılar:'
      @uyarilar.each { |u| satirlar << "  - #{u}" }
    end
    unless @hatalar.empty?
      satirlar << ''
      satirlar << 'Hatalar:'
      @hatalar.each { |h| satirlar << "  - #{h}" }
    end
    File.open(File.join(klasor, 'rapor.txt'), 'w') { |f| f.write(satirlar.join("\n") + "\n") }
  end

  def ozet
    sure = Time.now - @baslangic
    puts
    bilgi Renk.mavi('— Özet —')
    bilgi "  Sayfa:       #{@sayaclar[:sayfa]}"
    bilgi "  CSS:         #{@sayaclar[:css]}"
    bilgi "  Varlık:      #{@sayaclar[:varlik]}"
    bilgi "  Toplam boyut: #{boyut(@sayaclar[:bayt])}"
    bilgi format('  Süre:        %.1f sn', sure)
    @uyarilar.each { |u| puts "  #{Renk.sari('!')} #{u}" }
    @hatalar.first(10).each { |h| puts "  #{Renk.kirmizi('✗')} #{h}" }
    if @hatalar.size > 10
      bilgi "  #{Renk.kirmizi('✗')} … ve #{@hatalar.size - 10} hata daha (rapor.txt)"
    end
    ana = @haritalar[@kok] || @haritalar.values.first
    if ana
      puts
      bilgi "  #{Renk.yesil('Açmak için:')} open \"#{File.expand_path(File.join(@ayar[:cikti], ana))}\""
    end
  end

  # --------------------------------------------------------- yardımcılar ---
  def paralel(liste, &blok)
    return if liste.empty?
    sayi = [@ayar[:is], liste.size].min
    kuyruk = Queue.new
    liste.each { |l| kuyruk << l }
    sayi.times { kuyruk << nil }
    threads = sayi.times.map do
      Thread.new do
        while (l = kuyruk.pop)
          begin
            blok.call(l)
          rescue StandardError => e
            @kilit.synchronize do
              @hatalar << "#{l.is_a?(Array) ? l.first : l}: #{e.class}: #{e.message}"
            end
            puts "  #{Renk.kirmizi('!')} #{e.class}: #{e.message}" if @ayar[:acik]
          end
        end
      end
    end
    threads.each(&:join)
  end

  def srcset_urlleri(deger, taban)
    deger.split(',').map do |p|
      ilk = p.strip.split(/\s+/).first.to_s
      next nil if ilk.empty? || ilk =~ /\Adata:/i
      normallestir(ilk, taban)
    end.compact
  end

  def css_urlleri(metin, taban)
    return [] if metin.nil? || metin.empty?
    sonuclar = []
    metin.scan(CSS_URL_RE) do
      hammadde = Regexp.last_match(2).to_s.strip
      next if hammadde.empty? || hammadde.start_with?('#') || hammadde =~ /\Adata:/i
      sonuclar << normallestir(hammadde, taban)
    end
    metin.scan(CSS_IMPORT_RE) do
      hammadde = Regexp.last_match(1)
      next if hammadde =~ /\Adata:/i
      sonuclar << normallestir(hammadde, taban)
    end
    sonuclar.compact
  end

  def metin_olarak(baytlar)
    m = baytlar.to_s.dup
    m.force_encoding('UTF-8')
    return m if m.valid_encoding?
    m.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
  rescue StandardError
    baytlar.to_s.dup.force_encoding('BINARY')
  end

  def html_cikti(doc)
    c = doc.to_html
    c = c.dup.force_encoding(c.encoding || 'UTF-8')
    c = c.encode('UTF-8', invalid: :replace, undef: :replace)
    c = c.sub(/\A(<\?xml[^>]*?)encoding=["'][^"']*["']/i, '\1encoding="UTF-8"')
    c
  rescue StandardError
    doc.to_s
  end

  def disk_yaz(yol, icerik)
    tam = File.join(@ayar[:cikti], yol)
    begin
      FileUtils.mkdir_p(File.dirname(tam))
    rescue SystemCallError
      # yolun bir bileşeni dosya olarak yazılmış olabilir (aynı anda
      # dosya/dizin çakışması) — yolu düzleştirip yeniden dene
      duz = File.join(@ayar[:cikti], '_catisma', yol.tr('/', '_'))
      begin
        FileUtils.mkdir_p(File.dirname(duz))
        tam = duz
      rescue SystemCallError => e2
        @kilit.synchronize { @hatalar << "Yazılamadı: #{yol} (#{e2.message})" }
        return nil
      end
    end
    File.open(tam, 'wb') { |f| f.write(icerik) }
    tam
  rescue SystemCallError => e
    @kilit.synchronize { @hatalar << "Yazılamadı: #{yol} (#{e.message})" }
    nil
  end

  def boyut(b)
    return "#{b} B" if b < 1024
    return format('%.1f KB', b / 1024.0) if b < 1024 * 1024
    format('%.1f MB', b / (1024.0 * 1024))
  end

  def bilgi(s)
    puts s unless @ayar[:sessiz]
  end
end

# ------------------------------------------------------------------ CLI ---
if __FILE__ == $PROGRAM_NAME
  ayar = {
    cikti: nil, derinlik: 4, is: 5, sayfa_limit: 1000, varlik_limit: 10_000,
    hiz: 0.1, zaman_asimi: 30, maks_mb: 150, ua: SiteKopyala::VARSAYILAN_UA,
    harici_sayfa: false, sadece_kendi: false, ssl_dogrula: true,
    robots: false, sessiz: false, acik: false
  }

  yolcu = OptionParser.new do |o|
    o.banner = <<~BANNER
      Site Kopyala — web sitesini tam olarak indirip çevrimdışı çalışır hale getirir.

      Kullanım: ruby site_kopyala.rb URL [seçenekler]
      Örnek:    ruby site_kopyala.rb https://ornek.com -o ornek-cikti -d 6
    BANNER

    o.on('-o DIR', '--cikti DIR', 'Çıktı klasörü (varsayılan: alanadi-yilaygun)') { |v| ayar[:cikti] = v }
    o.on('-d N', '--derinlik N', Integer, 'Taranacak bağlantı derinliği (varsayılan: 4)') { |v| ayar[:derinlik] = v }
    o.on('-j N', '--is N', Integer, 'Eşzamanlı iş parçacığı (varsayılan: 5)') { |v| ayar[:is] = v }
    o.on('-s N', '--sayfa N', Integer, 'En fazla sayfa sayısı (varsayılan: 1000)') { |v| ayar[:sayfa_limit] = v }
    o.on('--varlik N', Integer, 'En fazla varlık (dosya) sayısı (varsayılan: 10000)') { |v| ayar[:varlik_limit] = v }
    o.on('--hiz SN', Float, 'İstekler arası bekleme, saniye (varsayılan: 0.1)') { |v| ayar[:hiz] = v }
    o.on('--zaman-asimi SN', Float, 'Bağlantı zaman aşımı, saniye (varsayılan: 30)') { |v| ayar[:zaman_asimi] = v }
    o.on('--maks-mb N', Integer, 'Dosya başına azami boyut, MB (varsayılan: 150)') { |v| ayar[:maks_mb] = v }
    o.on('--tarayici UA', 'Özel User-Agent (bazı siteler engelleyebilir)') { |v| ayar[:ua] = v }
    o.on('--harici-sayfa', 'Diğer alan adlarındaki sayfaları da kopyala') { ayar[:harici_sayfa] = true }
    o.on('--sadece-kendi', 'Yalnızca hedef alan adının varlıklarını indir') { ayar[:sadece_kendi] = true }
    o.on('--ssl-yoksay', 'SSL sertifika doğrulamasını kapat') { ayar[:ssl_dogrula] = false }
    o.on('--robots', "robots.txt kurallarına uy") { ayar[:robots] = true }
    o.on('--sessiz', 'Sessiz mod (yalnızca özet)') { ayar[:sessiz] = true }
    o.on('--acik', 'Ayrıntılı çıktı (hata ayıklama)') { ayar[:acik] = true }
    o.on('-h', '--yardim', 'Bu yardımı göster') do
      puts o
      exit
    end
  end

  begin
    yolcu.parse!
  rescue OptionParser::ParseError => e
    warn e.message
    warn yolcu
    exit 1
  end

  hedef = ARGV.shift
  unless hedef
    warn yolcu
    exit 1
  end
  hedef = 'https://' + hedef unless hedef =~ %r{\Ahttps?://}i

  begin
    host = URI.parse(hedef).host.to_s.downcase
  rescue URI::InvalidURIError
    host = ''
  end
  ayar[:cikti] ||= "#{host.empty? ? 'site' : host}_#{Time.now.strftime('%Y%m%d-%H%M')}"

  # hedef zaten bir HTML dosyası gibi görünüyorsa çıktı adını düzelt
  if File.exist?(ayar[:cikti]) && !File.directory?(ayar[:cikti])
    ayar[:cikti] += '_klasor'
  end

  begin
    SiteKopyala.new(hedef, ayar).kopyala
  rescue Interrupt
    warn "\nKesildi."
    exit 130
  rescue StandardError => e
    warn Renk.kirmizi("Hata: #{e.class}: #{e.message}")
    warn e.backtrace.first(5).join("\n") if ayar[:acik]
    exit 1
  end
end
