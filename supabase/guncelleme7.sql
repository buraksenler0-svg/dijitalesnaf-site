-- ═══════════════════════════════════════════════════════════════════════════════════════════
--  DIGITAL ESNAF · GÜNCELLEME 7: 7 GÜNLÜK DENEME, PRO 399 TL, PRO'YA FARK ÖDEYEREK GEÇİŞ KURALI
-- ═══════════════════════════════════════════════════════════════════════════════════════════
--  Nasıl çalıştırılır:
--    Supabase > SQL Editor > New query içine bu dosyanın TAMAMINI yapıştırıp "Run" deyin.
--    "Potential issues detected" uyarısı çıkarsa çalıştırmayı onaylayın.
--    Önce Güncelleme 6 (guncelleme6.sql) çalıştırılmış olmalı. Tekrar çalıştırmak güvenlidir.
--    Hiçbir işletme kaydını silmez.
--
--  Ne değişir:
--    * Deneme süresi 7 gün. Yeni kayıtlar bu süreyle başlar; şu an denemede olanların süresi kısalmaz.
--      Süre Kontrol Merkezi > Ayarlar'dan değiştirilebilir (1-60 gün).
--    * Pro paketinin varsayılan fiyatı 399 TL. Fiyat hâlâ eski varsayılan (499 TL) ise 399 TL olur;
--      Kontrol Merkezi'nden elle başka bir fiyat yazdıysanız ona dokunulmaz.
--    * Standart'tan Pro'ya aradaki farkı ödeyerek geçiş yalnızca ödenmiş Standart ay devam ederken yapılır.
--      Denemedeki, aboneliği bitmiş ya da doğrudan Pro alan işletme Pro'nun aylık ücretini öder.
--      Bu kural ekranda değil, veritabanında uygulanır.
-- ═══════════════════════════════════════════════════════════════════════════════════════════

-- 0) Ön koşul: Güncelleme 6 kurulu olmalı -------------------------------------------------------------
do $$ begin
  if to_regprocedure('public.tel_giris(text, text)') is null or to_regclass('public.hesap_tel') is null then
    raise exception 'Önce Güncelleme 6 (guncelleme6.sql) çalıştırılmalı. Sonra bu dosyayı yeniden çalıştırın.';
  end if;
end $$;

-- 1) Ayarlar: deneme süresi (gün) ve Pro fiyatı ---------------------------------------------------------
alter table sistem add column if not exists deneme_gun int not null default 7;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'sistem_deneme_gun_check') then
    alter table sistem add constraint sistem_deneme_gun_check check (deneme_gun between 1 and 60);
  end if;
end $$;
alter table isletme alter column deneme_bitis set default (current_date + 7);
alter table sistem alter column fiyat_pro set default 399;
update sistem set fiyat_pro = 399, guncelleme = now() where id = 1 and fiyat_pro = 499;

-- 2) Yeni işletme: deneme süresi ayardan alınır -----------------------------------------------------------
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
  -- deneme süresi ayardan (Güncelleme 7: sistem.deneme_gun); ayar yoksa 7 gün. Güncellemeler hangi sırayla çalışırsa çalışsın aynı sonuç.
  gun int := coalesce((select (to_jsonb(s)->>'deneme_gun')::int from sistem s where s.id = 1), 7);
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
      insert into isletme (ad, kod, sektor, plan, deneme_bitis)
      values (trim(p_ad), k, coalesce(nullif(trim(p_sektor), ''), 'diger'), case when p_plan = 'standart' then 'standart' else 'pro' end,
              current_date + gun)
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

-- 3) Pro'ya fark ödeyerek geçiş yalnızca ödenmiş ve süresi devam eden Standart abonelikte -----------------
--    Ödeme bildirimi (tur 'odeme') seçilen paketin tam aylık ücretiyle gönderilir.
create or replace function talep_olustur(p_tur text, p_aciklama text default null, p_plan text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme();
  i isletme%rowtype;
  s sistem%rowtype;
  t talep%rowtype;
  hedef text;
  tut numeric;
  acik text := nullif(left(trim(coalesce(p_aciklama, '')), 500), '');
begin
  if isl is null or not yonetici_ham(isl) then raise exception 'Bu işlemi yalnızca işletme sahibi yapabilir'; end if;
  if p_tur not in ('pro', 'odeme') then raise exception 'Geçersiz talep'; end if;
  select * into i from isletme where id = isl;
  select * into s from sistem where id = 1;
  if p_tur = 'pro' then
    if i.plan = 'pro' or i.ucretsiz then raise exception 'İşletmen zaten Pro pakette'; end if;
    if i.odeme_bitis is null or i.odeme_bitis < current_date then
      raise exception 'Farkı ödeyerek Pro’ya geçiş yalnızca ödenmiş Standart ayın devam ederken yapılabilir. Pro paketini aylık ücretiyle alabilirsin.';
    end if;
    hedef := 'pro';
    tut := greatest(s.fiyat_pro - s.fiyat_standart, 0);
  else
    hedef := case when coalesce(p_plan, i.plan) = 'pro' then 'pro' else 'standart' end;
    tut := case when hedef = 'pro' then s.fiyat_pro else s.fiyat_standart end;
  end if;
  select * into t from talep where isletme_id = isl and tur = p_tur and durum = 'bekliyor' order by created_at desc limit 1;
  if found then
    update talep set plan = hedef, tutar = tut, aciklama = coalesce(acik, aciklama), created_at = now(), user_id = auth.uid()
    where id = t.id returning * into t;
  else
    insert into talep (isletme_id, tur, plan, tutar, aciklama) values (isl, p_tur, hedef, tut, acik) returning * into t;
  end if;
  return to_jsonb(t);
end $$;

-- 4) Fiyatlar ve deneme süresi (tanıtım sayfası ve kayıt ekranı okur) -------------------------------------
create or replace function fiyatlar() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('standart', s.fiyat_standart, 'pro', s.fiyat_pro, 'deneme_gun', s.deneme_gun) from sistem s where s.id = 1
$$;

-- 5) Kontrol Merkezi ayarları: deneme süresi de kaydedilir -------------------------------------------------
create or replace function kurucu_ayar_kaydet(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sistem%rowtype;
begin
  if not kurucu_mu() then raise exception 'Yetki yok'; end if;
  if coalesce((p->>'fiyat_standart')::numeric, 1) <= 0 or coalesce((p->>'fiyat_pro')::numeric, 1) <= 0 then
    raise exception 'Fiyat sıfırdan büyük olmalı';
  end if;
  if coalesce((p->>'ai_standart')::int, 0) < 0 or coalesce((p->>'ai_pro')::int, 0) < 0 or coalesce(nullif(p->>'ai_deneme', '')::int, 0) < 0 then
    raise exception 'Soru hakkı eksi olamaz';
  end if;
  if coalesce(nullif(p->>'ai_gunluk', '')::int, 1) < 1 then raise exception 'Günlük AI sınırı en az 1 olmalı'; end if;
  if coalesce(nullif(p->>'sube_standart', '')::int, 1) < 1 or coalesce(nullif(p->>'sube_pro', '')::int, 1) < 1 then
    raise exception 'Şube sınırı en az 1 olmalı';
  end if;
  if p ? 'deneme_gun' and coalesce(nullif(p->>'deneme_gun', '')::int, 0) not between 1 and 60 then
    raise exception 'Deneme süresi 1 ile 60 gün arasında olmalı';
  end if;
  update sistem set
    fiyat_standart = coalesce((p->>'fiyat_standart')::numeric, fiyat_standart),
    fiyat_pro = coalesce((p->>'fiyat_pro')::numeric, fiyat_pro),
    ai_standart = coalesce((p->>'ai_standart')::int, ai_standart),
    ai_pro = coalesce((p->>'ai_pro')::int, ai_pro),
    ai_deneme = case when p ? 'ai_deneme' then nullif(p->>'ai_deneme', '')::int else ai_deneme end,
    ai_gunluk = case when p ? 'ai_gunluk' then nullif(p->>'ai_gunluk', '')::int else ai_gunluk end,
    sube_standart = case when p ? 'sube_standart' then coalesce(nullif(p->>'sube_standart', '')::int, 1) else sube_standart end,
    sube_pro = case when p ? 'sube_pro' then nullif(p->>'sube_pro', '')::int else sube_pro end,
    deneme_gun = case when p ? 'deneme_gun' then (p->>'deneme_gun')::int else deneme_gun end,
    iban = case when p ? 'iban' then nullif(upper(regexp_replace(p->>'iban', '\s', '', 'g')), '') else iban end,
    alici = case when p ? 'alici' then nullif(trim(p->>'alici'), '') else alici end,
    banka = case when p ? 'banka' then nullif(trim(p->>'banka'), '') else banka end,
    iletisim = case when p ? 'iletisim' then nullif(trim(p->>'iletisim'), '') else iletisim end,
    odeme_notu = case when p ? 'odeme_notu' then nullif(trim(p->>'odeme_notu'), '') else odeme_notu end,
    guncelleme = now()
  where id = 1
  returning * into s;
  return to_jsonb(s);
end $$;

-- 6) Fonksiyon izinleri ---------------------------------------------------------------------------------
revoke all on function fiyatlar() from public;
grant execute on function fiyatlar() to anon, authenticated;
revoke all on function isletme_olustur(text, text, text, text, text, text), talep_olustur(text, text, text),
  kurucu_ayar_kaydet(jsonb) from public, anon;
grant execute on function isletme_olustur(text, text, text, text, text, text), talep_olustur(text, text, text),
  kurucu_ayar_kaydet(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- Kontrol
select 'Güncelleme 7 kuruldu' as durum,
       (select deneme_gun from sistem where id = 1) as deneme_gun,
       (select fiyat_standart from sistem where id = 1) as standart,
       (select fiyat_pro from sistem where id = 1) as pro;
