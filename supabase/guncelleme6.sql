-- ═══════════════════════════════════════════════════════════════════════════════════════════
--  DIGITAL ESNAF · GÜNCELLEME 6: TELEFONLA GİRİŞ VE OTOMATİK İŞLETME KODU (DE + 5 RAKAM)
-- ═══════════════════════════════════════════════════════════════════════════════════════════
--  Nasıl çalıştırılır:
--    Supabase > SQL Editor > New query içine bu dosyanın TAMAMINI yapıştırıp "Run" deyin.
--    "Potential issues detected" uyarısı çıkarsa çalıştırmayı onaylayın.
--    Önce Güncelleme 5 (guncelleme5.sql) çalıştırılmış olmalı. Tekrar çalıştırmak güvenlidir.
--    Hiçbir işletme kaydını silmez.
--
--  Ne değişir:
--    * İşletme kodunu artık sistem verir. Kod her zaman DE ile başlar, sonunda 5 rakam vardır (ör. DE48213).
--      Kayıt olan kişi kod seçemez. İki işletmeye hiçbir zaman aynı kod verilmez; aynı anda kayıt olsalar
--      bile veritabanının benzersizlik kuralı ikinciyi durdurur ve ona kendiliğinden yeni bir kod verilir.
--    * Mevcut işletmelerin kodu da DE koduna çevrilir. Eski kod kaybolmaz: çalışanlar eski kodla da giriş
--      yapabilir, müşterilere verilmiş servis bağlantıları ve çalışan giriş bağlantıları çalışmaya devam eder.
--    * İşletme sahipleri cep telefonu numarası ve şifreyle giriş yapar; e-postayla giriş de çalışmaya devam eder.
--      Bir numara yalnızca bir hesapta kayıtlı olabilir. Art arda yanlış şifre denemeleri sınırlanır.
-- ═══════════════════════════════════════════════════════════════════════════════════════════

-- 0) Ön koşul: Güncelleme 5 kurulu olmalı -------------------------------------------------------------
do $$ begin
  if to_regprocedure('public.rol_mi(uuid, text[])') is null or to_regclass('public.onay') is null then
    raise exception 'Önce Güncelleme 5 (guncelleme5.sql) çalıştırılmalı. Sonra bu dosyayı yeniden çalıştırın.';
  end if;
end $$;

-- 1) Tablolar -----------------------------------------------------------------------------------------
-- İşletme sahibinin giriş numarası (10 hane, 5 ile başlar). Bir numara yalnızca bir hesapta olabilir.
create table if not exists hesap_tel (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tel text not null unique check (tel ~ '^5[0-9]{9}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table hesap_tel enable row level security;
revoke all on table hesap_tel from anon, authenticated;

-- Kod değişen işletmelerin eski kodları: eski bağlantılar ve eski kodla çalışan girişi çalışsın diye
create table if not exists isletme_eski_kod (
  kod text primary key,
  isletme_id uuid not null references isletme(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists isletme_eski_kod_isl_ix on isletme_eski_kod (isletme_id);
alter table isletme_eski_kod enable row level security;
revoke all on table isletme_eski_kod from anon, authenticated;

-- Giriş ve numara kontrol denemeleri (art arda denemeleri sınırlamak için; 1 günden eskiler silinir)
create table if not exists giris_deneme (
  id bigint generated always as identity primary key,
  anahtar text not null,
  zaman timestamptz not null default now(),
  basarili boolean not null default false
);
create index if not exists giris_deneme_ix on giris_deneme (anahtar, zaman desc);
create index if not exists giris_deneme_zaman_ix on giris_deneme (zaman);
alter table giris_deneme enable row level security;
revoke all on table giris_deneme from anon, authenticated;

-- 2) Yardımcılar --------------------------------------------------------------------------------------
-- Cep numarasını tek biçime getirir: "0532 123 45 67", "+90 532...", "905321234567" → "5321234567"
create or replace function tel_duzelt(p text) returns text
language sql immutable set search_path = public as $$
  select case
    when d ~ '^00905[0-9]{9}$' then substr(d, 4)
    when d ~ '^905[0-9]{9}$' then substr(d, 3)
    when d ~ '^05[0-9]{9}$' then substr(d, 2)
    when d ~ '^5[0-9]{9}$' then d
  end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$$;

-- İsteği gönderenin IP adresi (Supabase'in önündeki Cloudflare'in yazdığı başlık; yoksa ilk yönlendirme adresi).
-- Adres okunamazsa ya da iç ağ adresiyse (sunucunun kendi adresi olabilir) "bilinmiyor" döner ve IP sınırı uygulanmaz;
-- böylece yanlış okunan bir adres yüzünden herkesin telefonla girişi durmaz.
create or replace function istemci_ip() returns text
language plpgsql stable set search_path = public as $$
declare h jsonb; ip text; a inet;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then h := null;
  end;
  ip := coalesce(nullif(trim(h->>'cf-connecting-ip'), ''), nullif(trim(h->>'x-real-ip'), ''),
                 nullif(trim(split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1)), ''));
  if ip is null then return 'bilinmiyor'; end if;
  begin
    a := ip::inet;
  exception when others then return 'bilinmiyor';
  end;
  if a << '10.0.0.0/8' or a << '172.16.0.0/12' or a << '192.168.0.0/16' or a << '127.0.0.0/8' or a << '100.64.0.0/10'
     or a << '169.254.0.0/16' or a << 'fc00::/7' or a << 'fe80::/10' or a = '::1' then
    return 'bilinmiyor';
  end if;
  return host(a);
end $$;

-- Kullanılmayan bir işletme kodu: "de" + 10000-99999 arası 5 rakam (ekranda büyük harfle DE48213 görünür).
-- Seçilen kod başka bir işletmede ya da eski kodlar arasında olmamalı. Son karar benzersizlik kuralındadır.
create or replace function yeni_isletme_kodu() returns text
language plpgsql volatile security definer set search_path = public as $$
declare k text; n int := 0;
begin
  loop
    k := 'de' || (10000 + floor(random() * 90000))::int;
    exit when not exists (select 1 from isletme where kod = k)
          and not exists (select 1 from isletme_eski_kod where kod = k);
    n := n + 1;
    if n >= 500 then raise exception 'Boş işletme kodu bulunamadı, lütfen tekrar deneyin'; end if;
  end loop;
  return k;
end $$;

-- Yazılan kodun bugünkü hâli: güncel kod ya da eski kod verilirse işletmenin güncel kodu döner, yoksa boş
create or replace function kod_coz(p_kod text) returns text
language sql stable security definer set search_path = public as $$
  with g as (select lower(regexp_replace(coalesce(p_kod, ''), '[^A-Za-z0-9]', '', 'g')) as k)
  select coalesce(
    (select i.kod from isletme i, g where i.kod = g.k),
    (select i.kod from isletme_eski_kod e join isletme i on i.id = e.isletme_id, g where e.kod = g.k))
$$;

-- 3) Mevcut işletmelerin kodları DE koduna çevrilir -----------------------------------------------------
--    Çalışan hesaplarının giriş adresleri (kullanici.kod@calisan.dijitalesnaf.app) yeni koda taşınır.
--    Eski kod isletme_eski_kod tablosunda kalır; eski kodla giriş ve eski bağlantılar çalışır.
do $$
declare r record; y text; m record; e_eski text; e_yeni text;
begin
  for r in select id, kod from isletme where kod !~ '^de[0-9]{5}$' order by created_at, id loop
    y := yeni_isletme_kodu();
    insert into isletme_eski_kod (kod, isletme_id) values (r.kod, r.id) on conflict (kod) do nothing;
    update isletme set kod = y where id = r.id;
    for m in select u.user_id, u.kullanici from uye u where u.isletme_id = r.id and u.kullanici is not null loop
      e_eski := m.kullanici || '.' || r.kod || '@calisan.dijitalesnaf.app';
      e_yeni := m.kullanici || '.' || y || '@calisan.dijitalesnaf.app';
      -- Yeni adres hiçbir işletmeye bağlı olmayan bir hesapta duruyorsa önce o hesap silinir
      delete from auth.users au where lower(au.email) = e_yeni and au.id <> m.user_id
        and not exists (select 1 from uye x where x.user_id = au.id);
      update auth.users set email = e_yeni, updated_at = now() where id = m.user_id and lower(email) = e_eski;
      begin
        update auth.identities set identity_data = identity_data || jsonb_build_object('email', e_yeni), updated_at = now()
        where user_id = m.user_id and provider = 'email' and lower(identity_data->>'email') = e_eski;
      exception when others then null;
      end;
    end loop;
    delete from calisan_davet where isletme_id = r.id;   -- yarım kalmış davetler eski adresi taşır
    raise notice 'İşletme kodu değişti: % → %', r.kod, upper(y);
  end loop;
end $$;

-- Kayıt sırasında (bu güncellemeden önce) kullanıcı bilgisine yazılmış numaralar telefon tablosuna alınır
insert into hesap_tel (user_id, tel)
select distinct on (t.tel) t.id, t.tel
from (select au.id, au.created_at, tel_duzelt(au.raw_user_meta_data->>'tel') as tel
      from auth.users au
      where lower(coalesce(au.email, '')) not like '%@calisan.dijitalesnaf.app'
        and exists (select 1 from uye u where u.user_id = au.id and u.rol = 'yonetici')) t
where t.tel is not null
  and not exists (select 1 from hesap_tel h where h.user_id = t.id)
order by t.tel, t.created_at
on conflict do nothing;

-- 4) Yeni işletme: kodu sistem verir, sahibin cep numarası kaydedilir ----------------------------------
--    p_kod eski uygulama sürümleri için durur; yazılsa da kullanılmaz.
drop function if exists isletme_olustur(text, text, text, text);
drop function if exists isletme_olustur(text, text, text, text, text);
create or replace function isletme_olustur(p_ad text, p_kod text default null, p_sektor text default 'diger',
                                           p_yonetici_ad text default null, p_plan text default 'pro',
                                           p_tel text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  i isletme%rowtype;
  t text := tel_duzelt(p_tel);
  k text;
  n int := 0;
  c text;
begin
  if auth.uid() is null then raise exception 'Önce giriş yapın'; end if;
  if coalesce(auth.jwt()->>'email', '') like '%@calisan.dijitalesnaf.app' then raise exception 'Çalışan hesabıyla işletme açılamaz'; end if;
  if exists (select 1 from uye where user_id = auth.uid()) then raise exception 'Bu hesap zaten bir işletmeye bağlı'; end if;
  if length(trim(coalesce(p_ad, ''))) < 2 then raise exception 'İşletme adını yazın'; end if;
  if trim(coalesce(p_tel, '')) <> '' and t is null then raise exception 'Cep telefonu numaranızı 05XX XXX XX XX biçiminde yazın'; end if;
  if t is not null then
    if (select count(*) from giris_deneme where anahtar = 'olustur:' || auth.uid() and zaman > now() - interval '1 hour') >= 10 then
      raise exception 'Çok fazla deneme yapıldı. Bir saat sonra yeniden deneyin.';
    end if;
    if exists (select 1 from hesap_tel where tel = t and user_id <> auth.uid()) then
      insert into giris_deneme (anahtar) values ('olustur:' || auth.uid());
      return jsonb_build_object('hata', 'Bu cep telefonu numarası başka bir hesapta kayıtlı. O hesapla giriş yapın ya da başka bir numara yazın.');
    end if;
    begin
      insert into hesap_tel (user_id, tel) values (auth.uid(), t)
      on conflict (user_id) do update set tel = excluded.tel, updated_at = now();
    exception when unique_violation then
      return jsonb_build_object('hata', 'Bu cep telefonu numarası başka bir hesapta kayıtlı. O hesapla giriş yapın ya da başka bir numara yazın.');
    end;
  end if;
  -- Kod: DE + 5 rakam. Aynı anda iki kayıt aynı kodu seçerse benzersizlik kuralı ikinciyi durdurur, ona yeni kod seçilir.
  loop
    k := yeni_isletme_kodu();
    begin
      insert into isletme (ad, kod, sektor, plan)
      values (trim(p_ad), k, coalesce(nullif(trim(p_sektor), ''), 'diger'), case when p_plan = 'standart' then 'standart' else 'pro' end)
      returning * into i;
      exit;
    exception when unique_violation then
      get stacked diagnostics c = constraint_name;
      n := n + 1;
      if c is distinct from 'isletme_kod_key' or n >= 25 then raise; end if;
    end;
  end loop;
  insert into uye (isletme_id, user_id, rol, ad) values (i.id, auth.uid(), 'yonetici', nullif(trim(coalesce(p_yonetici_ad, '')), ''));
  return to_jsonb(i);
end $$;

-- 5) Telefonla giriş ------------------------------------------------------------------------------------
-- Numara ve şifre doğruysa hesabın e-posta adresini verir; uygulama girişi bununla tamamlar.
-- Yanlışsa boş döner (numaranın kayıtlı olup olmadığı söylenmez). Sınırlar: bir numaraya 15 dakikada
-- 8 yanlış deneme, bir IP adresinden 15 dakikada 40 yanlış deneme, bütün sistemde dakikada 300 deneme.
create or replace function tel_giris(p_tel text, p_sifre text) returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  t text := tel_duzelt(p_tel);
  ip text := istemci_ip();
  u record;
  ok boolean := false;
begin
  if t is null then raise exception 'Cep telefonu numaranızı 05XX XXX XX XX biçiminde yazın'; end if;
  if coalesce(p_sifre, '') = '' then raise exception 'Şifrenizi yazın'; end if;
  if (select count(*) from giris_deneme where anahtar = 'tel:' || t and not basarili and zaman > now() - interval '15 minutes') >= 8
     or (ip <> 'bilinmiyor' and (select count(*) from giris_deneme where anahtar = 'ip:' || ip and not basarili
                                 and zaman > now() - interval '15 minutes') >= 40)
     or (select count(*) from giris_deneme where zaman > now() - interval '1 minute') >= 600 then
    raise exception 'Çok fazla deneme yapıldı. 15 dakika sonra yeniden deneyin ya da e-posta adresinizle giriş yapın.';
  end if;
  select au.id, au.email::text as email, au.encrypted_password::text as sifre into u
  from hesap_tel h join auth.users au on au.id = h.user_id
  where h.tel = t and au.deleted_at is null;
  if u.id is not null and coalesce(u.sifre, '') like '$2%' then
    ok := u.sifre = extensions.crypt(p_sifre, u.sifre);
  else
    perform extensions.crypt(p_sifre, '$2a$10$cHsg0lfK28HZ2L5AUvT1RO');   -- kayıtlı olmayan numarada da aynı süre
  end if;
  insert into giris_deneme (anahtar, basarili) values ('tel:' || t, ok), ('ip:' || ip, ok);
  delete from giris_deneme where zaman < now() - interval '1 day';
  if ok then return u.email; end if;
  return null;
end $$;

-- Kayıt ekranı: numara başka bir hesapta kayıtlı mı? (IP adresi başına 15 dakikada 30 kontrol)
create or replace function tel_kayitli(p_tel text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare t text := tel_duzelt(p_tel); ip text := istemci_ip();
begin
  if t is null then raise exception 'Cep telefonu numaranızı 05XX XXX XX XX biçiminde yazın'; end if;
  if ip <> 'bilinmiyor' and (select count(*) from giris_deneme where anahtar = 'kontrol:' || ip
                             and zaman > now() - interval '15 minutes') >= 30 then
    raise exception 'Çok fazla deneme yapıldı. Biraz sonra yeniden deneyin.';
  end if;
  insert into giris_deneme (anahtar, basarili) values ('kontrol:' || ip, true);
  return exists (select 1 from hesap_tel where tel = t);
end $$;

-- Giriş yapmış işletme sahibi cep numarasını ekler ya da değiştirir (çalışan hesaplarında yok)
create or replace function tel_kaydet(p_tel text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare t text := tel_duzelt(p_tel);
begin
  if auth.uid() is null then raise exception 'Önce giriş yapın'; end if;
  if coalesce(auth.jwt()->>'email', '') like '%@calisan.dijitalesnaf.app' then raise exception 'Çalışan hesaplarına telefon eklenmez'; end if;
  if t is null then raise exception 'Cep telefonu numaranızı 05XX XXX XX XX biçiminde yazın'; end if;
  if (select count(*) from giris_deneme where anahtar = 'tel_kaydet:' || auth.uid() and zaman > now() - interval '1 hour') >= 10 then
    raise exception 'Çok fazla deneme yapıldı. Bir saat sonra yeniden deneyin.';
  end if;
  insert into giris_deneme (anahtar) values ('tel_kaydet:' || auth.uid());
  if exists (select 1 from hesap_tel where tel = t and user_id <> auth.uid()) then
    return jsonb_build_object('hata', 'Bu numara başka bir hesapta kayıtlı.');
  end if;
  begin
    insert into hesap_tel (user_id, tel) values (auth.uid(), t)
    on conflict (user_id) do update set tel = excluded.tel, updated_at = now();
  exception when unique_violation then
    return jsonb_build_object('hata', 'Bu numara başka bir hesapta kayıtlı.');
  end;
  return jsonb_build_object('tel', t);
end $$;

-- 6) Hesap bilgisi: giriş numarası da gelir -------------------------------------------------------------
create or replace function benim() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'isletme', to_jsonb(i), 'rol', u.rol, 'ad', u.ad, 'kullanici', u.kullanici,
    'kurucu', exists (select 1 from kurucu k where k.user_id = auth.uid()),
    'abone', i.ucretsiz or current_date <= greatest(i.deneme_bitis, coalesce(i.odeme_bitis, i.deneme_bitis)),
    'pro', i.plan = 'pro' or i.ucretsiz,
    'bitis', greatest(i.deneme_bitis, coalesce(i.odeme_bitis, i.deneme_bitis)),
    'fiyat', (select jsonb_build_object('standart', s.fiyat_standart, 'pro', s.fiyat_pro) from sistem s where s.id = 1),
    'sube_id', u.sube_id,
    'sube_limit', sube_limit(i.id),
    'subeler', coalesce((select jsonb_agg(jsonb_build_object('id', sb.id, 'ad', sb.ad, 'adres', sb.adres, 'telefon', sb.telefon)
                                          order by sb.created_at, sb.id)
                         from sube sb where sb.isletme_id = i.id and sb.aktif), '[]'::jsonb),
    'tel', (select h.tel from hesap_tel h where h.user_id = auth.uid()))
  from uye u join isletme i on i.id = u.isletme_id
  where u.user_id = auth.uid() and u.aktif
  order by u.created_at
  limit 1
$$;

-- 7) Müşterilere açık sayfalar eski kodla da çalışır ---------------------------------------------------
create or replace function servis_sorgula(p_isletme text, p_kod text, p_tel4 text)
returns table (cihaz text, ariza text, durum text, tarih date, teslim date, ucret numeric, musteri_notu text, ilk_ad text)
language sql stable security definer set search_path = public as $$
  select s.cihaz, s.ariza, s.durum, s.tarih, s.teslim, s.ucret, s.musteri_notu,
         split_part(trim(coalesce(s.musteri, '')), ' ', 1)
  from servis s join isletme i on i.id = s.isletme_id
  where i.kod = kod_coz(p_isletme)
    and upper(s.takip_kodu) = upper(trim(coalesce(p_kod, '')))
    and length(regexp_replace(coalesce(p_tel4, ''), '\D', '', 'g')) = 4
    and right(regexp_replace(coalesce(s.tel, ''), '\D', '', 'g'), 4) = regexp_replace(p_tel4, '\D', '', 'g')
  limit 1
$$;

create or replace function vitrin(p_isletme text)
returns table (id uuid, tur text, alttur text, marka text, ad text, depo text, renk text, sat numeric, adet integer, resim text, resimler jsonb, ozellik jsonb, yeni boolean)
language sql stable security definer set search_path = public as $$
  select s.id, s.tur, s.alttur, s.marka, s.ad, s.depo, s.renk, s.sat, s.adet, s.resim, s.resimler, s.ozellik,
         s.created_at > now() - interval '14 days'
  from stok s join isletme i on i.id = s.isletme_id
  where i.kod = kod_coz(p_isletme) and s.vitrinde and s.adet > 0
    and coalesce(i.ayarlar #>> '{site,vitrin}', 'false') = 'true'
  order by s.created_at desc
$$;

create or replace function isletme_site(p_isletme text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ad', i.ad, 'sektor', i.sektor, 'kod', i.kod, 'site', coalesce(i.ayarlar->'site', '{}'::jsonb))
  from isletme i where i.kod = kod_coz(p_isletme)
$$;

-- Kurucuyu belirler (yalnızca SQL Editor'den çalışır): eski ya da yeni kodla
create or replace function kurucu_yap_kod(p_kod text) returns text
language plpgsql security definer set search_path = public as $$
declare isl uuid; uid uuid;
begin
  select id into isl from isletme where kod = kod_coz(p_kod);
  if isl is null then return 'İşletme bulunamadı: ' || coalesce(p_kod, ''); end if;
  select user_id into uid from uye where isletme_id = isl and rol = 'yonetici' order by created_at limit 1;
  if uid is null then return 'İşletmenin yöneticisi bulunamadı'; end if;
  insert into kurucu (user_id) values (uid) on conflict (user_id) do nothing;
  update isletme set ucretsiz = true, plan = 'pro' where id = isl;
  return 'Tamam';
end $$;

-- 8) Fonksiyon izinleri ---------------------------------------------------------------------------------
revoke all on function yeni_isletme_kodu(), istemci_ip(), kurucu_yap_kod(text) from public, anon, authenticated;
revoke all on function tel_duzelt(text) from public, anon, authenticated;
revoke all on function kod_coz(text), tel_giris(text, text), tel_kayitli(text), servis_sorgula(text, text, text),
  vitrin(text), isletme_site(text) from public;
grant execute on function kod_coz(text), tel_giris(text, text), tel_kayitli(text), servis_sorgula(text, text, text),
  vitrin(text), isletme_site(text) to anon, authenticated;
revoke all on function isletme_olustur(text, text, text, text, text, text), tel_kaydet(text), benim() from public, anon;
grant execute on function isletme_olustur(text, text, text, text, text, text), tel_kaydet(text), benim() to authenticated;

notify pgrst, 'reload schema';

-- Kontrol
select 'Güncelleme 6 kuruldu' as durum,
       (select count(*) from isletme) as isletme,
       (select count(*) from isletme where kod ~ '^de[0-9]{5}$') as de_kodlu,
       (select string_agg(upper(kod), ', ' order by created_at) from isletme) as kodlar;
