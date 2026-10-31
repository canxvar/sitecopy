# Kurulum (tek seferlik)

GitHub, `.github/workflows/` altındaki dosyaları yalnızca web arayüzünden veya
`workflow` yetkili bir jetonla eklemeye izin veriyor. Panel jeton istemediği için
bu iki dosyayı bir kez elle eklemen gerekiyor.

## 1) kopyala.yml

1. Şu adresi aç: <https://github.com/canxvar/sitecopy/new/main/.github/workflows/kopyala.yml>
   (klasör yoksa GitHub yolun tamamını oluşturur — dosya adı kutusuna
   `.github/workflows/kopyala.yml` yazman yeterli.)
2. [`kopyala.yml`](./kopyala.yml) dosyasını aç, sağ üstteki **Raw** → tümünü seç → kopyala.
3. GitHub'da içerik alanına yapıştır → **Commit changes**.

## 2) sil.yml

Aynı adımlar: <https://github.com/canxvar/sitecopy/new/main/.github/workflows/sil.yml>
içeriği [`sil.yml`](./sil.yml).

## 3) Dene

<https://github.com/canxvar/sitecopy/actions/workflows/kopyala.yml> →
**Run workflow** → adresi yaz → **Run**. Bitince
<https://canxvar.github.io/sitecopy/> listesinde görünür.

Bu `kurulum/` klasörü iş bitince silinebilir; panelin çalışması için gerekli değil.
