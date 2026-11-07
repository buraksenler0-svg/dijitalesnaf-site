# Digital Esnaf AI · site

`site/` klasöründeki dosyalar her güncellemede Cloudflare Pages'teki **dijitalesnaf** projesine kendiliğinden yüklenir
(`.github/workflows/yayinla.yml`). Sonucu **Actions** sekmesinden görebilirsiniz.

- `site/index.html` · tanıtım sayfası (digitalesnaf.com). Servis, onay, çalışan girişi ve şifre yenileme bağlantılarını
  uygulamaya aktarır; giriş yapmış kişiyi ve telefona yüklenmiş uygulamayı doğrudan panele gönderir.
- `site/app/index.html` · uygulama (digitalesnaf.com/app).
- `site/kontrol/index.html` · Kontrol Merkezi (digitalesnaf.com/kontrol): yalnızca kurucu hesabıyla açılan, uygulamadan
  ayrı girişi ve oturumu olan yönetim sayfası. Arama motorlarına kapalıdır; yetki her işlemde veritabanında denetlenir.
- `site/yasal.html` · yasal metinler.
- `supabase/` · Supabase SQL Editor'e yapıştırılacak güncellemeler ve asistan fonksiyonu (kopyalamak için).

Gerekli gizli bilgi: `CLOUDFLARE_API_TOKEN` (Settings › Secrets and variables › Actions).
Sayfalardaki Supabase anahtarı herkese açık (anon) anahtardır; gizli anahtarlar bu depoda yoktur ve olmamalıdır.
