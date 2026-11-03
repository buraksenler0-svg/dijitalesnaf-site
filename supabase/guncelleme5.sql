-- ═══════════════════════════════════════════════════════════════════════════════════════════
--  DİJİTAL ESNAF AI · GÜNCELLEME 5: EKİP GÖREVLERİ, ONAY SİSTEMİ, MÜŞTERİDEN CİHAZ ALIMI
-- ═══════════════════════════════════════════════════════════════════════════════════════════
--  Nasıl çalıştırılır:
--    Supabase > SQL Editor > New query içine bu dosyanın TAMAMINI yapıştırıp "Run" deyin.
--    "Potential issues detected" uyarısı çıkarsa çalıştırmayı onaylayın.
--    Önce Güncelleme 4 (guncelleme4.sql) çalıştırılmış olmalı. Tekrar çalıştırmak güvenlidir.
--    Hiçbir kaydı silmez. Mevcut "çalışan" hesapları "Teknik servis" görevinde kalır.
--
--  Ne değişir:
--    * Dört görev: Yönetici, Mağaza müdürü, Personel, Teknik servis.
--      Müdür ve personel ciro, kâr, gelir, gider, kasa ve raporları göremez (veritabanı da vermez).
--    * Müdür ve personelin satış, ürün ekleme, stok girişi, stoktan düşme ve cihaz alımları
--      yöneticinin onayına düşer; onaylanmadan gerçekleşmez. Onay bekleyen satıştaki ürün başkasına satılamaz.
--    * Müşteriden cihaz alımı: müşteri bilgileri, cihaz bilgileri, hasar fotoğrafları, müşterinin linkten
--      onayı, imzalı belgenin fotoğrafı. Belgeler herkese kapalı "belgeler" klasöründe durur.
--    * Ödenen alış bedeli günün kasasına çıkış olarak yazılır.
--    * Asistan, müdür ve personele para bilgisi vermez; sorarlarsa nazikçe reddeder.
-- ═══════════════════════════════════════════════════════════════════════════════════════════

-- 0) Ön koşul: Güncelleme 4 kurulu olmalı -------------------------------------------------------------
do $$ begin
  if to_regclass('public.calisan_davet') is null or to_regprocedure('public.calisan_hazirla(text)') is null then
    raise exception 'Önce Güncelleme 4 (guncelleme4.sql) çalıştırılmalı. Sonra bu dosyayı yeniden çalıştırın.';
  end if;
end $$;

-- 1) Görevler -----------------------------------------------------------------------------------------
alter table uye drop constraint if exists uye_rol_check;
alter table uye add constraint uye_rol_check check (rol in ('yonetici', 'mudur', 'personel', 'calisan'));

-- Kişinin bu işletmede verilen görevlerden birinde olup olmadığı (abonelik ve paket kurallarıyla)
create or replace function rol_mi(p uuid, p_roller text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from uye u join isletme i on i.id = u.isletme_id
    where u.isletme_id = p and u.user_id = auth.uid() and u.aktif and u.rol = any(p_roller)
      and (i.ucretsiz or current_date <= greatest(i.deneme_bitis, coalesce(i.odeme_bitis, i.deneme_bitis)))
      and (u.rol = 'yonetici' or i.plan = 'pro' or i.ucretsiz))
$$;

-- Teknik servis kayıtlarını yalnızca yönetici ve teknik servis yazar; müdür ve personel yalnızca bakar
drop policy if exists servis_ekle on servis;
create policy servis_ekle on servis for insert to authenticated
  with check (rol_mi(isletme_id, array['yonetici', 'calisan']) and sube_erisim(isletme_id, sube_id));
drop policy if exists servis_guncelle on servis;
create policy servis_guncelle on servis for update to authenticated
  using (rol_mi(isletme_id, array['yonetici', 'calisan']) and sube_erisim(isletme_id, sube_id))
  with check (rol_mi(isletme_id, array['yonetici', 'calisan']) and sube_erisim(isletme_id, sube_id));

-- Müdür ve personel stoğu görür (kendi şubesine bağlıysa yalnız o şubeyi); yazamaz, değişiklik onaydan geçer
drop policy if exists stok_ekip_oku on stok;
create policy stok_ekip_oku on stok for select to authenticated
  using (rol_mi(isletme_id, array['mudur', 'personel']) and sube_erisim(isletme_id, sube_id));

-- Müdür, onaya göndereceği yeni ürünün fotoğrafını yükleyebilir
drop policy if exists "urunler_yaz" on storage.objects;
create policy "urunler_yaz" on storage.objects for insert to authenticated
  with check (bucket_id = 'urunler' and rol_mi(((storage.foldername(name))[1])::uuid, array['yonetici', 'mudur']));

-- Ekibe kişi bağlama: dört görevden biriyle (davet kodu Güncelleme 4'teki gibi zorunlu)
create or replace function calisan_bagla(p_kullanici text, p_ad text default null, p_rol text default 'calisan', p_sube uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme();
  k text;
  ku text := lower(trim(coalesce(p_kullanici, '')));
  e text;
  hedef uuid;
  dv calisan_davet%rowtype;
begin
  if isl is null or not yonetici_mi(isl) then raise exception 'Yetki yok'; end if;
  if not pro_mi(isl) then raise exception 'Ekip Pro pakette. Pro''ya geçince çalışan ekleyebilirsin.'; end if;
  if p_rol not in ('yonetici', 'mudur', 'personel', 'calisan') then raise exception 'Geçersiz görev'; end if;
  if ku !~ '^[a-z0-9_]{3,20}$' then raise exception 'Kullanıcı adı 3-20 harf veya rakam olmalı'; end if;
  if p_sube is not null and not exists (select 1 from sube where id = p_sube and isletme_id = isl and aktif) then
    raise exception 'Şube bulunamadı';
  end if;
  select kod into k from isletme where id = isl;
  e := ku || '.' || k || '@calisan.dijitalesnaf.app';
  select id into hedef from auth.users where lower(email) = e;
  if hedef is null then raise exception 'Hesap bulunamadı'; end if;
  if exists (select 1 from uye where user_id = hedef) then raise exception 'Bu kullanıcı zaten ekli'; end if;
  -- Hesap bu yöneticinin az önce verdiği davetle açılmış olmalı
  select * into dv from calisan_davet where eposta = e;
  if dv.eposta is null or dv.isletme_id <> isl or dv.son < now()
     or coalesce((select raw_user_meta_data->>'davet' from auth.users where id = hedef), '') <> dv.kod then
    raise exception 'Çalışan hesabı doğrulanamadı. Çalışanı yeniden eklemeyi deneyin.';
  end if;
  insert into uye (isletme_id, user_id, rol, ad, kullanici, sube_id)
  values (isl, hedef, p_rol, nullif(trim(coalesce(p_ad, '')), ''), ku, p_sube);
  -- Bu adreslere e-posta gidemez; "Confirm email" açık kalmışsa bile çalışan giriş yapabilsin. Davet kodu silinir.
  update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()),
                        raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) - 'davet'
  where id = hedef;
  delete from calisan_davet where eposta = e;
end $$;

-- Ekipteki birinin görevini değiştir (kendini ve son yöneticiyi değiştiremez); kişinin açık oturumları kapanır
create or replace function uye_rol(p_user uuid, p_rol text) returns void
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); r text;
begin
  if isl is null or not yonetici_mi(isl) then raise exception 'Yetki yok'; end if;
  if p_rol not in ('yonetici', 'mudur', 'personel', 'calisan') then raise exception 'Geçersiz görev'; end if;
  if p_user = auth.uid() then raise exception 'Kendi görevini değiştiremezsin'; end if;
  select rol into r from uye where user_id = p_user and isletme_id = isl;
  if r is null then raise exception 'Bu kişi ekibinizde değil'; end if;
  if p_rol <> 'yonetici' and not pro_mi(isl) then raise exception 'Ekip Pro pakette. Pro''ya geçince ekip görevleri açılır.'; end if;
  if r = 'yonetici' and p_rol <> 'yonetici'
     and (select count(*) from uye where isletme_id = isl and rol = 'yonetici' and aktif) <= 1 then
    raise exception 'Son yönetici değiştirilemez';
  end if;
  if r is distinct from p_rol then
    update uye set rol = p_rol where user_id = p_user and isletme_id = isl;
    perform oturumlari_kapat(p_user);   -- açık oturumu kapanır, yeni görevin ekranlarıyla yeniden girer
  end if;
end $$;

-- Son 30 günde ürün başına satılan adet (para yok): yönetici, müdür ve personel
create or replace function stok_satis_hizi(p_sube uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare isl uuid := aktif_isletme();
begin
  if isl is null or not rol_mi(isl, array['yonetici', 'mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  return coalesce((select jsonb_object_agg(x.sid, x.n) from (
    select s.sid, sum(case when s.tip = 'iade' then -s.adet else s.adet end) as n
    from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s
    where s.isletme_id = isl and s.sid is not null and s.tarih > tr_bugun() - 30 and (p_sube is null or s.sube_id = p_sube)
    group by s.sid having sum(case when s.tip = 'iade' then -s.adet else s.adet end) > 0) x), '{}'::jsonb);
end $$;

-- 2) Onay sistemi: müdür ve personelin işlemleri yönetici onaylayınca gerçekleşir --------------------------
create table if not exists onay (
  id uuid primary key default gen_random_uuid(),
  isletme_id uuid not null references isletme(id) on delete cascade,
  sube_id uuid references sube(id) on delete set null,
  created_at timestamptz not null default now(),
  isteyen uuid not null,
  isteyen_ad text,
  isteyen_rol text,
  tur text not null check (tur in ('satis', 'urun_ekle', 'stok_giris', 'stok_dusme', 'alim')),
  veri jsonb not null default '{}'::jsonb,
  ozet text not null default '',
  tutar numeric,
  durum text not null default 'bekliyor' check (durum in ('bekliyor', 'onaylandi', 'reddedildi', 'iptal')),
  karar_veren uuid,
  karar_zaman timestamptz,
  karar_not text,
  sonuc jsonb
);
create index if not exists onay_isletme_ix on onay (isletme_id, durum, created_at desc);
create index if not exists onay_isteyen_ix on onay (isteyen, created_at desc);
alter table onay enable row level security;
drop policy if exists onay_oku on onay;
create policy onay_oku on onay for select to authenticated
  using (yonetici_mi(isletme_id) or (isteyen = auth.uid() and uye_ham(isletme_id)));
revoke all on table onay from anon, authenticated;
grant select on table onay to authenticated;

-- Onay bekleyen satışlarda ayrılmış adet (o ürün başka satışa verilmez)
create or replace function stok_ayrilan(p_stok uuid, p_haric uuid default null) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum((k->>'adet')::int), 0)::int
  from onay o cross join lateral jsonb_array_elements(o.veri->'kalemler') k
  where o.tur = 'satis' and o.durum = 'bekliyor' and o.id is distinct from p_haric and k->>'stok_id' = p_stok::text
$$;

create or replace function stok_ayrilanlar() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.sid, x.n), '{}'::jsonb) from (
    select k->>'stok_id' as sid, sum((k->>'adet')::int) as n
    from onay o cross join lateral jsonb_array_elements(o.veri->'kalemler') k
    where o.isletme_id = aktif_isletme() and rol_mi(o.isletme_id, array['yonetici', 'mudur', 'personel'])
      and o.tur = 'satis' and o.durum = 'bekliyor' and k->>'stok_id' is not null
    group by 1) x
$$;

create or replace function onay_ekle(p_isl uuid, p_sube uuid, p_tur text, p_veri jsonb, p_ozet text, p_tutar numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare u uye%rowtype; yeni uuid;
begin
  select * into u from uye where isletme_id = p_isl and user_id = auth.uid() and aktif;
  if (select count(*) from onay where isletme_id = p_isl and isteyen = auth.uid() and durum = 'bekliyor') >= 200 then
    raise exception 'Çok fazla onay bekleyen işlem var. Yöneticinin onaylamasını bekleyin.';
  end if;
  insert into onay (isletme_id, sube_id, isteyen, isteyen_ad, isteyen_rol, tur, veri, ozet, tutar)
  values (p_isl, p_sube, auth.uid(), coalesce(nullif(btrim(coalesce(u.ad, '')), ''), u.kullanici, ''), u.rol, p_tur, p_veri, left(coalesce(p_ozet, ''), 300), p_tutar)
  returning id into yeni;
  return yeni;
end $$;

-- Satışın kendisi (içeriden çağrılır): yöneticinin satışı ve onaylanan satış aynı yoldan geçer
create or replace function satis_isle(p_isl uuid, p_sube uuid, p_kalemler jsonb, p_odeme text, p_aciklama text, p_tarih date, p_personel uuid, p_haric uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  isl uuid := p_isl;
  ayr int;
  f uuid := gen_random_uuid();
  t date := coalesce(p_tarih, tr_bugun());
  k jsonb;
  st stok%rowtype;
  n int;
  fy numeric;
  ml numeric;
  sid uuid;
  ad text;
  yeni uuid;
  toplam numeric := 0;
  say int := 0;
begin
  if isl is null then raise exception 'Yetki yok'; end if;
  if coalesce(p_odeme, '') not in ('Nakit', 'Kart', 'Havale') then raise exception 'Ödeme şeklini seçin'; end if;
  if not exists (select 1 from sube where id = p_sube and isletme_id = isl and aktif) then raise exception 'Şube bulunamadı'; end if;
  if t > tr_bugun() then raise exception 'İleri tarihli satış girilemez'; end if;
  if t < tr_bugun() - 366 then raise exception 'Bir yıldan eski tarihe satış girilemez'; end if;
  if p_kalemler is null or jsonb_typeof(p_kalemler) <> 'array' or jsonb_array_length(p_kalemler) = 0 then
    raise exception 'Sepet boş';
  end if;
  if jsonb_array_length(p_kalemler) > 100 then raise exception 'Bir satışta en fazla 100 kalem olabilir'; end if;
  perform set_config('de.hareket', 'islem', true);
  for k in select value from jsonb_array_elements(p_kalemler) order by value->>'stok_id' nulls last loop
    begin
      n := (k->>'adet')::int;
      fy := nullif(k->>'fiyat', '')::numeric;
      sid := nullif(k->>'stok_id', '')::uuid;
    exception when others then
      raise exception 'Sepetteki bir kalem okunamadı';
    end;
    if n is null or n < 1 or n > 100000 then raise exception 'Adet en az 1 olmalı'; end if;
    if fy is not null and (fy < 0 or fy > 100000000) then raise exception 'Fiyat geçersiz'; end if;
    if sid is not null then
      select * into st from stok where id = sid and isletme_id = isl for update;
      if not found then raise exception 'Ürün bulunamadı. Sayfayı yenileyin.'; end if;
      if st.sube_id <> p_sube then raise exception '% bu şubenin stoğunda değil', stok_ad(st); end if;
      ayr := stok_ayrilan(sid, p_haric);
      if st.adet - ayr < n then
        if ayr > 0 then
          raise exception '% için stok yetersiz (stokta % adet var, % adedi onay bekleyen satışta)', stok_ad(st), st.adet, ayr;
        end if;
        raise exception '% için stok yetersiz (stokta % adet var)', stok_ad(st), st.adet;
      end if;
      fy := coalesce(fy, st.sat);
      ml := st.alis;
      ad := stok_ad(st);
      update stok set adet = adet - n where id = sid;
    else
      ad := nullif(btrim(coalesce(k->>'ad', '')), '');
      if ad is null then raise exception 'Elle eklenen ürünün adını yazın'; end if;
      if fy is null then raise exception '% için fiyat yazın', ad; end if;
      ml := greatest(coalesce(nullif(k->>'maliyet', '')::numeric, 0), 0);
    end if;
    insert into satis (isletme_id, sube_id, tarih, sid, ad, adet, fiyat, maliyet, odeme_yontem, tip, fis, aciklama, personel)
    values (isl, p_sube, t, sid, left(ad, 200), n, fy, ml, p_odeme, 'normal', f, nullif(btrim(coalesce(p_aciklama, '')), ''), coalesce(p_personel, auth.uid()))
    returning id into yeni;
    if sid is not null then
      insert into stok_hareket (isletme_id, sube_id, stok_id, tur, adet, ref) values (isl, p_sube, sid, 'satis', -n, yeni);
    end if;
    toplam := toplam + n * fy;
    say := say + 1;
  end loop;
  return jsonb_build_object('fis', f, 'toplam', toplam, 'kalem', say, 'odeme', p_odeme, 'tarih', t);
end $$;

create or replace function satis_yap(p_sube uuid, p_kalemler jsonb, p_odeme text default 'Nakit', p_aciklama text default null, p_tarih date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme();
begin
  if isl is null or not yonetici_mi(isl) then raise exception 'Yetki yok'; end if;
  return satis_isle(isl, p_sube, p_kalemler, p_odeme, p_aciklama, p_tarih, auth.uid(), null);
end $$;

-- Müdür ve personel: satış onaya gider
create or replace function satis_iste(p_sube uuid, p_kalemler jsonb, p_odeme text default 'Nakit', p_aciklama text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme();
  k jsonb; n int; fy numeric; sid uuid; st stok%rowtype; ad text; ayr int; istenen int;
  harita jsonb := '{}'::jsonb; kalemler jsonb := '[]'::jsonb; toplam numeric := 0; say int := 0; yeni uuid;
begin
  if isl is null or not rol_mi(isl, array['mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  if coalesce(p_odeme, '') not in ('Nakit', 'Kart', 'Havale') then raise exception 'Ödeme şeklini seçin'; end if;
  if not exists (select 1 from sube where id = p_sube and isletme_id = isl and aktif) then raise exception 'Şube bulunamadı'; end if;
  if not sube_erisim(isl, p_sube) then raise exception 'Yalnızca kendi şubende satış yapabilirsin'; end if;
  if p_kalemler is null or jsonb_typeof(p_kalemler) <> 'array' or jsonb_array_length(p_kalemler) = 0 then raise exception 'Sepet boş'; end if;
  if jsonb_array_length(p_kalemler) > 100 then raise exception 'Bir satışta en fazla 100 kalem olabilir'; end if;
  for k in select value from jsonb_array_elements(p_kalemler) loop
    begin
      n := (k->>'adet')::int; fy := nullif(k->>'fiyat', '')::numeric; sid := nullif(k->>'stok_id', '')::uuid;
    exception when others then raise exception 'Sepetteki bir kalem okunamadı';
    end;
    if n is null or n < 1 or n > 100000 then raise exception 'Adet en az 1 olmalı'; end if;
    if fy is not null and (fy < 0 or fy > 100000000) then raise exception 'Fiyat geçersiz'; end if;
    if sid is not null then
      select * into st from stok where id = sid and isletme_id = isl;
      if not found then raise exception 'Ürün bulunamadı. Sayfayı yenileyin.'; end if;
      if st.sube_id <> p_sube then raise exception '% bu şubenin stoğunda değil', stok_ad(st); end if;
      istenen := coalesce((harita->>sid::text)::int, 0) + n;
      harita := harita || jsonb_build_object(sid::text, istenen);
      ayr := stok_ayrilan(sid, null);
      if st.adet - ayr < istenen then
        if ayr > 0 then
          raise exception '% için stok yetersiz (stokta % adet var, % adedi onay bekleyen satışta)', stok_ad(st), st.adet, ayr;
        end if;
        raise exception '% için stok yetersiz (stokta % adet var)', stok_ad(st), st.adet;
      end if;
      fy := coalesce(fy, st.sat); ad := stok_ad(st);
      kalemler := kalemler || jsonb_build_array(jsonb_build_object('stok_id', sid, 'ad', ad, 'adet', n, 'fiyat', fy));
    else
      ad := nullif(btrim(coalesce(k->>'ad', '')), '');
      if ad is null then raise exception 'Elle eklenen ürünün adını yazın'; end if;
      if fy is null then raise exception '% için fiyat yazın', ad; end if;
      kalemler := kalemler || jsonb_build_array(jsonb_build_object('ad', left(ad, 200), 'adet', n, 'fiyat', fy));
    end if;
    toplam := toplam + n * fy; say := say + 1;
  end loop;
  yeni := onay_ekle(isl, p_sube, 'satis',
    jsonb_build_object('kalemler', kalemler, 'odeme', p_odeme, 'aciklama', nullif(btrim(coalesce(p_aciklama, '')), '')),
    'Satış · ' || say || ' kalem · ' || p_odeme, toplam);
  return jsonb_build_object('id', yeni, 'toplam', toplam, 'kalem', say, 'odeme', p_odeme);
end $$;

-- Müdür: yeni ürün onaya gider
create or replace function urun_iste(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme(); s uuid; ad text; alis numeric; sat numeric; adet int; kritik int; resim text;
begin
  if isl is null or not rol_mi(isl, array['mudur']) then raise exception 'Yetki yok'; end if;
  ad := btrim(coalesce(p->>'ad', ''));
  if length(ad) < 2 then raise exception 'Ürün adını yazın'; end if;
  begin
    alis := coalesce(nullif(p->>'alis', '')::numeric, 0); sat := coalesce(nullif(p->>'sat', '')::numeric, 0);
    adet := coalesce(nullif(p->>'adet', '')::int, 0); kritik := coalesce(nullif(p->>'kritik', '')::int, 3);
  exception when others then raise exception 'Fiyat ve adet sayı olmalı';
  end;
  if alis < 0 or sat < 0 or alis > 100000000 or sat > 100000000 then raise exception 'Fiyatlar 0 ya da daha büyük olmalı'; end if;
  if adet < 0 or adet > 100000 then raise exception 'Adet 0 ya da daha büyük bir tam sayı olmalı'; end if;
  if kritik < 0 then raise exception 'Azalma uyarısı tam sayı olmalı'; end if;
  s := coalesce(nullif(p->>'sube_id', '')::uuid, (select sube_id from uye where isletme_id = isl and user_id = auth.uid()), varsayilan_sube(isl));
  if not exists (select 1 from sube where id = s and isletme_id = isl and aktif) or not sube_erisim(isl, s) then raise exception 'Şube bulunamadı'; end if;
  resim := nullif(btrim(coalesce(p->>'resim', '')), '');
  if resim is not null and position('/storage/v1/object/public/urunler/' || isl::text || '/' in resim) = 0 then resim := null; end if;
  return onay_ekle(isl, s, 'urun_ekle',
    jsonb_build_object('ad', left(ad, 120), 'marka', nullif(left(btrim(coalesce(p->>'marka', '')), 60), ''), 'tur', coalesce(nullif(left(btrim(coalesce(p->>'tur', '')), 60), ''), 'Ürün'),
      'depo', nullif(left(btrim(coalesce(p->>'depo', '')), 60), ''), 'renk', nullif(left(btrim(coalesce(p->>'renk', '')), 40), ''),
      'imei', nullif(left(btrim(coalesce(p->>'imei', '')), 60), ''), 'alis', alis, 'sat', sat, 'adet', adet, 'kritik', kritik, 'resim', resim),
    'Yeni ürün · ' || concat_ws(' ', nullif(btrim(coalesce(p->>'marka', '')), ''), ad) || ' · ' || adet || ' adet', adet * alis);
end $$;

-- Müdür: stok girişi onaya gider
create or replace function stok_giris_iste(p_stok uuid, p_adet int, p_alis numeric default null, p_aciklama text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); st stok%rowtype;
begin
  if isl is null or not rol_mi(isl, array['mudur']) then raise exception 'Yetki yok'; end if;
  if p_adet is null or p_adet < 1 or p_adet > 100000 then raise exception 'Adet en az 1 olmalı'; end if;
  if p_alis is not null and (p_alis < 0 or p_alis > 100000000) then raise exception 'Alış fiyatı geçersiz'; end if;
  select * into st from stok where id = p_stok and isletme_id = isl;
  if not found or not sube_erisim(isl, st.sube_id) then raise exception 'Ürün bulunamadı'; end if;
  return onay_ekle(isl, st.sube_id, 'stok_giris',
    jsonb_build_object('stok_id', st.id, 'ad', stok_ad(st), 'adet', p_adet, 'alis', p_alis, 'aciklama', nullif(left(btrim(coalesce(p_aciklama, '')), 200), '')),
    'Stok girişi · ' || stok_ad(st) || ' · +' || p_adet || ' adet', p_adet * coalesce(p_alis, st.alis));
end $$;

-- Müdür: stoktan düşme (bozuk, kayıp vb.) onaya gider; sebep zorunlu. Personel satışsız stok düşemez.
create or replace function stok_dusme_iste(p_stok uuid, p_adet int, p_aciklama text) returns uuid
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); st stok%rowtype; neden text := nullif(left(btrim(coalesce(p_aciklama, '')), 200), '');
begin
  if isl is null or not rol_mi(isl, array['mudur']) then raise exception 'Yetki yok'; end if;
  if p_adet is null or p_adet < 1 or p_adet > 100000 then raise exception 'Adet en az 1 olmalı'; end if;
  if neden is null or length(neden) < 3 then raise exception 'Stoktan düşme sebebini yazın'; end if;
  select * into st from stok where id = p_stok and isletme_id = isl;
  if not found or not sube_erisim(isl, st.sube_id) then raise exception 'Ürün bulunamadı'; end if;
  if st.adet - stok_ayrilan(st.id, null) < p_adet then raise exception '% için stokta yeterli adet yok', stok_ad(st); end if;
  return onay_ekle(isl, st.sube_id, 'stok_dusme',
    jsonb_build_object('stok_id', st.id, 'ad', stok_ad(st), 'adet', p_adet, 'aciklama', neden),
    'Stoktan düşme · ' || stok_ad(st) || ' · −' || p_adet || ' adet', null);
end $$;

-- 3) Müşteriden cihaz alımı -----------------------------------------------------------------------------
alter table stok_hareket drop constraint if exists stok_hareket_tur_check;
alter table stok_hareket add constraint stok_hareket_tur_check
  check (tur in ('acilis', 'giris', 'satis', 'iade', 'transfer_cikis', 'transfer_giris', 'duzeltme', 'alim'));

create table if not exists alim (
  id uuid primary key default gen_random_uuid(),
  isletme_id uuid not null references isletme(id) on delete cascade,
  sube_id uuid references sube(id) on delete set null,
  created_at timestamptz not null default now(),
  olusturan uuid default auth.uid(),
  olusturan_ad text,
  musteri_ad text not null,
  musteri_tel text not null,
  marka text,
  model text not null,
  imei text,
  hafiza text,
  renk text,
  durum_tip text not null check (durum_tip in ('sifir', 'ikinci_el')),
  pil int check (pil between 0 and 100),
  hasar boolean not null default false,
  hasar_not text,
  hasar_foto text[] not null default '{}',
  alis numeric not null check (alis > 0),
  sat numeric check (sat >= 0),
  odeme_yontem text not null default 'Nakit' check (odeme_yontem in ('Nakit', 'Havale')),
  token text not null unique,
  token_son timestamptz not null,
  musteri_karar text check (musteri_karar in ('onay', 'red')),
  musteri_karar_zaman timestamptz,
  musteri_karar_iz jsonb,
  belge text,
  belge_zaman timestamptz,
  durum text not null default 'musteri_bekliyor'
    check (durum in ('musteri_bekliyor', 'musteri_onayladi', 'musteri_reddetti', 'yonetici_bekliyor', 'tamamlandi', 'reddedildi', 'iptal')),
  stok_id uuid,
  onay_id uuid
);
create index if not exists alim_isletme_ix on alim (isletme_id, created_at desc);
alter table alim enable row level security;
drop policy if exists alim_oku on alim;
create policy alim_oku on alim for select to authenticated
  using (rol_mi(isletme_id, array['yonetici', 'mudur', 'personel']) and sube_erisim(isletme_id, sube_id));
revoke all on table alim from anon, authenticated;
grant select on table alim to authenticated;

-- Belgeler (imzalı form ve hasar fotoğrafları): herkese KAPALI klasör; yalnızca işletmenin yönetici, müdür ve personeli
insert into storage.buckets (id, name, public) values ('belgeler', 'belgeler', false)
on conflict (id) do update set public = false;
drop policy if exists "belgeler_yaz" on storage.objects;
drop policy if exists "belgeler_oku" on storage.objects;
drop policy if exists "belgeler_sil" on storage.objects;
create policy "belgeler_yaz" on storage.objects for insert to authenticated
  with check (bucket_id = 'belgeler' and rol_mi(((storage.foldername(name))[1])::uuid, array['yonetici', 'mudur', 'personel']));
create policy "belgeler_oku" on storage.objects for select to authenticated
  using (bucket_id = 'belgeler' and rol_mi(((storage.foldername(name))[1])::uuid, array['yonetici', 'mudur', 'personel']));
create policy "belgeler_sil" on storage.objects for delete to authenticated
  using (bucket_id = 'belgeler' and yonetici_mi(((storage.foldername(name))[1])::uuid));

create or replace function alim_olustur(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme(); u uye%rowtype; s uuid; ad text; tel text; model text; dt text; pil int; al numeric; sa numeric;
  ody text; hs boolean; hn text; t text; yeni uuid;
begin
  if isl is null or not rol_mi(isl, array['yonetici', 'mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  ad := regexp_replace(btrim(coalesce(p->>'musteri_ad', '')), '\s+', ' ', 'g');
  if length(ad) < 5 or position(' ' in ad) = 0 then raise exception 'Müşterinin adını ve soyadını yazın'; end if;
  tel := regexp_replace(coalesce(p->>'musteri_tel', ''), '\D', '', 'g');
  if length(tel) = 12 and left(tel, 2) = '90' then tel := substr(tel, 3); end if;
  if length(tel) = 11 and left(tel, 1) = '0' then tel := substr(tel, 2); end if;
  if tel !~ '^5[0-9]{9}$' then raise exception 'Müşterinin cep telefonunu 05XX XXX XX XX biçiminde yazın'; end if;
  model := btrim(coalesce(p->>'model', ''));
  if length(model) < 2 then raise exception 'Cihazın modelini yazın'; end if;
  dt := p->>'durum_tip';
  if dt is null or dt not in ('sifir', 'ikinci_el') then raise exception 'Cihaz sıfır mı ikinci el mi, seçin'; end if;
  begin
    pil := nullif(p->>'pil', '')::int; al := nullif(p->>'alis', '')::numeric; sa := nullif(p->>'sat', '')::numeric;
  exception when others then raise exception 'Pil sağlığı ve fiyatlar sayı olmalı';
  end;
  if pil is not null and (pil < 0 or pil > 100) then raise exception 'Pil sağlığı 0 ile 100 arasında olmalı'; end if;
  if al is null or al <= 0 or al > 100000000 then raise exception 'Alış fiyatını yazın'; end if;
  if sa is not null and (sa < 0 or sa > 100000000) then raise exception 'Satış fiyatı geçersiz'; end if;
  ody := coalesce(nullif(p->>'odeme_yontem', ''), 'Nakit');
  if ody not in ('Nakit', 'Havale') then raise exception 'Ödeme şekli Nakit ya da Havale olmalı'; end if;
  hs := coalesce((p->>'hasar')::boolean, false);
  hn := nullif(left(btrim(coalesce(p->>'hasar_not', '')), 500), '');
  if hs and (hn is null or length(hn) < 3) then raise exception 'Hasarı kısaca yazın'; end if;
  select * into u from uye where isletme_id = isl and user_id = auth.uid() and aktif;
  s := coalesce(nullif(p->>'sube_id', '')::uuid, u.sube_id, varsayilan_sube(isl));
  if not exists (select 1 from sube where id = s and isletme_id = isl and aktif) or not sube_erisim(isl, s) then raise exception 'Şube bulunamadı'; end if;
  t := encode(extensions.gen_random_bytes(18), 'hex');
  insert into alim (isletme_id, sube_id, olusturan, olusturan_ad, musteri_ad, musteri_tel, marka, model, imei, hafiza, renk, durum_tip,
                    pil, hasar, hasar_not, alis, sat, odeme_yontem, token, token_son)
  values (isl, s, auth.uid(), coalesce(nullif(btrim(coalesce(u.ad, '')), ''), u.kullanici, ''), left(ad, 80), tel,
          nullif(left(btrim(coalesce(p->>'marka', '')), 40), ''), left(model, 80), nullif(left(regexp_replace(coalesce(p->>'imei', ''), '\s', '', 'g'), 40), ''),
          nullif(left(btrim(coalesce(p->>'hafiza', '')), 30), ''), nullif(left(btrim(coalesce(p->>'renk', '')), 30), ''), dt,
          pil, hs, case when hs then hn else null end, al, sa, ody, t, now() + interval '48 hours')
  returning id into yeni;
  return jsonb_build_object('id', yeni, 'token', t);
end $$;

-- Hasar fotoğraflarının yerleri (yükleme uygulamadan yapılır; yol işletmenin ve kaydın klasöründe olmalı)
create or replace function alim_foto(p_id uuid, p_yollar text[]) returns void
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); a alim%rowtype; y text;
begin
  if isl is null or not rol_mi(isl, array['yonetici', 'mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  select * into a from alim where id = p_id and isletme_id = isl for update;
  if not found or not sube_erisim(isl, a.sube_id) then raise exception 'Kayıt bulunamadı'; end if;
  if a.durum not in ('musteri_bekliyor', 'musteri_onayladi') then raise exception 'Bu kayıt artık değiştirilemez'; end if;
  if coalesce(array_length(p_yollar, 1), 0) > 8 then raise exception 'En fazla 8 fotoğraf eklenebilir'; end if;
  foreach y in array coalesce(p_yollar, '{}') loop
    if y not like isl::text || '/alim/' || a.id::text || '/%' then raise exception 'Fotoğraf yolu geçersiz'; end if;
  end loop;
  update alim set hasar_foto = coalesce(p_yollar, '{}') where id = a.id;
end $$;

-- Müşterinin onay sayfası (giriş gerekmez; bağlantıdaki tahmin edilemez kodla)
create or replace function alim_bilgi(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'isletme', i.ad, 'sube', sb.ad, 'tarih', a.created_at,
    'musteri_ad', a.musteri_ad, 'tel', '0' || left(a.musteri_tel, 3) || ' *** ** ' || right(a.musteri_tel, 2),
    'marka', a.marka, 'model', a.model, 'imei', a.imei, 'hafiza', a.hafiza, 'renk', a.renk, 'durum_tip', a.durum_tip,
    'pil', a.pil, 'hasar', a.hasar, 'hasar_not', a.hasar_not, 'hasar_foto', coalesce(array_length(a.hasar_foto, 1), 0),
    'alis', a.alis, 'odeme_yontem', a.odeme_yontem,
    'karar', a.musteri_karar, 'karar_zaman', a.musteri_karar_zaman,
    'suresi_doldu', a.token_son < now(), 'iptal', a.durum = 'iptal')
  from alim a join isletme i on i.id = a.isletme_id left join sube sb on sb.id = a.sube_id
  where length(coalesce(p_token, '')) >= 32 and a.token = p_token
$$;

create or replace function alim_karar(p_token text, p_onay boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a alim%rowtype; h jsonb;
begin
  if length(coalesce(p_token, '')) < 32 then raise exception 'Bağlantı geçersiz'; end if;
  select * into a from alim where token = p_token for update;
  if not found then raise exception 'Bağlantı geçersiz'; end if;
  if a.musteri_karar is not null then return jsonb_build_object('karar', a.musteri_karar, 'zaten', true); end if;
  if a.durum <> 'musteri_bekliyor' then raise exception 'Bu işlem artık onaylanamaz. Mağazayla görüşün.'; end if;
  if a.token_son < now() then raise exception 'Bağlantının süresi doldu. Mağazadan yeni bağlantı isteyin.'; end if;
  begin h := nullif(current_setting('request.headers', true), '')::jsonb; exception when others then h := null; end;
  update alim set musteri_karar = case when p_onay then 'onay' else 'red' end, musteri_karar_zaman = now(),
                  musteri_karar_iz = jsonb_build_object('ip', coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', h->>'x-forwarded-for'),
                                                        'tarayici', left(h->>'user-agent', 300)),
                  durum = case when p_onay then 'musteri_onayladi' else 'musteri_reddetti' end
  where id = a.id;
  return jsonb_build_object('karar', case when p_onay then 'onay' else 'red' end);
end $$;

-- Süresi dolan bağlantıyı yenile (müşteri henüz karar vermediyse)
create or replace function alim_link_yenile(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); a alim%rowtype; t text;
begin
  if isl is null or not rol_mi(isl, array['yonetici', 'mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  select * into a from alim where id = p_id and isletme_id = isl for update;
  if not found or not sube_erisim(isl, a.sube_id) then raise exception 'Kayıt bulunamadı'; end if;
  if a.durum <> 'musteri_bekliyor' then raise exception 'Müşteri zaten karar verdi'; end if;
  t := encode(extensions.gen_random_bytes(18), 'hex');
  update alim set token = t, token_son = now() + interval '48 hours' where id = a.id;
  return t;
end $$;

-- Alımı tamamla: cihaz stoğa 1 adet girer, hareket kaydı yazılır (yalnız içeriden çağrılır)
create or replace function alim_tamamla(p_alim uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a alim%rowtype; yeni uuid;
begin
  select * into a from alim where id = p_alim for update;
  if not found or a.belge is null or a.durum not in ('musteri_onayladi', 'yonetici_bekliyor') then raise exception 'Bu alım tamamlanamaz'; end if;
  perform set_config('de.hareket', 'islem', true);
  insert into stok (isletme_id, sube_id, tur, marka, ad, depo, renk, imei, alis, sat, adet, kritik)
  values (a.isletme_id, a.sube_id, case when a.durum_tip = 'ikinci_el' then 'İkinci el' else 'Telefon' end,
          a.marka, a.model, a.hafiza, a.renk, a.imei, a.alis, coalesce(a.sat, 0), 1, 0)
  returning id into yeni;
  insert into stok_hareket (isletme_id, sube_id, stok_id, tur, adet, aciklama, ref)
  values (a.isletme_id, a.sube_id, yeni, 'alim', 1, 'Müşteriden alım · ' || a.musteri_ad, a.id);
  update alim set durum = 'tamamlandi', stok_id = yeni where id = a.id;
  return jsonb_build_object('stok_id', yeni);
end $$;

-- İmzalı belgenin fotoğrafı: yönetici yüklerse alım hemen tamamlanır; müdür ve personelde yönetici onayına düşer
create or replace function alim_belge(p_id uuid, p_yol text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); a alim%rowtype; r jsonb; oid uuid;
begin
  if isl is null or not rol_mi(isl, array['yonetici', 'mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  select * into a from alim where id = p_id and isletme_id = isl for update;
  if not found or not sube_erisim(isl, a.sube_id) then raise exception 'Kayıt bulunamadı'; end if;
  if a.durum <> 'musteri_onayladi' then raise exception 'Önce müşteri bağlantıdan onaylamalı'; end if;
  if p_yol is null or p_yol not like isl::text || '/alim/' || a.id::text || '/%' then raise exception 'Belge yolu geçersiz'; end if;
  update alim set belge = p_yol, belge_zaman = now() where id = a.id;
  if yonetici_mi(isl) then
    r := alim_tamamla(a.id);
    return jsonb_build_object('durum', 'tamamlandi') || r;
  end if;
  oid := onay_ekle(isl, a.sube_id, 'alim', jsonb_build_object('alim_id', a.id),
    'Cihaz alımı · ' || concat_ws(' ', a.marka, a.model) || ' · ' || a.musteri_ad, a.alis);
  update alim set durum = 'yonetici_bekliyor', onay_id = oid where id = a.id;
  return jsonb_build_object('durum', 'yonetici_bekliyor', 'onay_id', oid);
end $$;

create or replace function alim_iptal(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); a alim%rowtype;
begin
  if isl is null or not rol_mi(isl, array['yonetici', 'mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  select * into a from alim where id = p_id and isletme_id = isl for update;
  if not found or not sube_erisim(isl, a.sube_id) then raise exception 'Kayıt bulunamadı'; end if;
  if a.durum not in ('musteri_bekliyor', 'musteri_onayladi', 'musteri_reddetti') then raise exception 'Belgesi yüklenmiş alım iptal edilemez'; end if;
  if not yonetici_mi(isl) and a.olusturan is distinct from auth.uid() then raise exception 'Yalnızca kaydı açan kişi ya da yönetici iptal edebilir'; end if;
  update alim set durum = 'iptal', token_son = now() where id = a.id;
end $$;

-- Onay kararı (yönetici): onaylanınca işlem gerçekleşir; olmazsa (ör. stok yetmezse) hata döner, işlem bekler
create or replace function onay_karar(p_id uuid, p_onay boolean, p_not text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); o onay%rowtype; r jsonb; st stok%rowtype; yeni uuid; n int; nt text := nullif(left(btrim(coalesce(p_not, '')), 300), '');
begin
  if isl is null or not yonetici_mi(isl) then raise exception 'Yetki yok'; end if;
  select * into o from onay where id = p_id and isletme_id = isl for update;
  if not found then raise exception 'İşlem bulunamadı'; end if;
  if o.durum <> 'bekliyor' then raise exception 'Bu işlem zaten sonuçlandı'; end if;
  if not coalesce(p_onay, false) then
    update onay set durum = 'reddedildi', karar_veren = auth.uid(), karar_zaman = now(), karar_not = nt where id = o.id;
    if o.tur = 'alim' then update alim set durum = 'reddedildi' where id = (o.veri->>'alim_id')::uuid and isletme_id = isl; end if;
    return jsonb_build_object('durum', 'reddedildi');
  end if;
  if o.tur = 'satis' then
    r := satis_isle(isl, o.sube_id, o.veri->'kalemler', o.veri->>'odeme', o.veri->>'aciklama', tr_bugun(), o.isteyen, o.id);
  elsif o.tur = 'urun_ekle' then
    insert into stok (isletme_id, sube_id, tur, marka, ad, depo, renk, imei, alis, sat, adet, kritik, resim, resimler)
    values (isl, o.sube_id, coalesce(o.veri->>'tur', 'Ürün'), o.veri->>'marka', o.veri->>'ad', o.veri->>'depo', o.veri->>'renk', o.veri->>'imei',
            coalesce((o.veri->>'alis')::numeric, 0), coalesce((o.veri->>'sat')::numeric, 0), coalesce((o.veri->>'adet')::int, 0),
            coalesce((o.veri->>'kritik')::int, 3), nullif(o.veri->>'resim', ''),
            case when nullif(o.veri->>'resim', '') is null then '[]'::jsonb else jsonb_build_array(o.veri->>'resim') end)
    returning id into yeni;
    r := jsonb_build_object('stok_id', yeni);
  elsif o.tur = 'stok_giris' then
    r := stok_giris((o.veri->>'stok_id')::uuid, (o.veri->>'adet')::int, nullif(o.veri->>'alis', '')::numeric,
                    concat_ws(' · ', o.veri->>'aciklama', 'Onaylı istek: ' || coalesce(o.isteyen_ad, '')));
  elsif o.tur = 'stok_dusme' then
    n := (o.veri->>'adet')::int;
    select * into st from stok where id = (o.veri->>'stok_id')::uuid and isletme_id = isl for update;
    if not found then raise exception 'Ürün bulunamadı'; end if;
    if st.adet - stok_ayrilan(st.id, null) < n then raise exception '% için stok yetersiz (stokta % adet var)', stok_ad(st), st.adet; end if;
    perform set_config('de.hareket', 'islem', true);
    update stok set adet = adet - n where id = st.id;
    insert into stok_hareket (isletme_id, sube_id, stok_id, tur, adet, aciklama, ref)
    values (isl, st.sube_id, st.id, 'duzeltme', -n, concat_ws(' · ', o.veri->>'aciklama', coalesce(o.isteyen_ad, '')), o.id);
    r := jsonb_build_object('stok_id', st.id, 'adet', st.adet - n);
  elsif o.tur = 'alim' then
    r := alim_tamamla((o.veri->>'alim_id')::uuid);
  end if;
  update onay set durum = 'onaylandi', karar_veren = auth.uid(), karar_zaman = now(), karar_not = nt, sonuc = r where id = o.id;
  return jsonb_build_object('durum', 'onaylandi', 'sonuc', r);
end $$;

-- İsteyen kişi bekleyen işlemini geri çekebilir (cihaz alımı hariç: para ödenmiş olabilir)
create or replace function onay_iptal(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o onay%rowtype;
begin
  select * into o from onay where id = p_id and isteyen = auth.uid() for update;
  if not found or o.durum <> 'bekliyor' then raise exception 'İşlem bulunamadı ya da sonuçlandı'; end if;
  if o.tur = 'alim' then raise exception 'Cihaz alımı geri çekilemez; yöneticiye haber verin'; end if;
  update onay set durum = 'iptal', karar_zaman = now() where id = o.id;
end $$;

-- Liste: yönetici işletmenin bütün işlemlerini, diğerleri yalnız kendi işlemlerini görür
create or replace function onay_listesi(p_gun int default 14) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare isl uuid := aktif_isletme(); y boolean;
begin
  if isl is null or not uye_ham(isl) then raise exception 'Yetki yok'; end if;
  y := yonetici_mi(isl);
  if not y and not rol_mi(isl, array['mudur', 'personel']) then raise exception 'Yetki yok'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id, 'created_at', o.created_at, 'tur', o.tur, 'ozet', o.ozet, 'tutar', o.tutar, 'durum', o.durum,
      'isteyen_ad', o.isteyen_ad, 'isteyen_rol', o.isteyen_rol, 'ben', o.isteyen = auth.uid(), 'sube', sb.ad, 'sube_id', o.sube_id,
      'veri', o.veri, 'karar_zaman', o.karar_zaman, 'karar_not', o.karar_not, 'sonuc', o.sonuc,
      'karar_veren', (select coalesce(nullif(u.ad, ''), u.kullanici) from uye u where u.user_id = o.karar_veren and u.isletme_id = isl),
      'alim', case when o.tur = 'alim' then (select jsonb_build_object('musteri_ad', a.musteri_ad, 'musteri_tel', a.musteri_tel, 'marka', a.marka,
          'model', a.model, 'imei', a.imei, 'hafiza', a.hafiza, 'renk', a.renk, 'durum_tip', a.durum_tip, 'pil', a.pil, 'hasar', a.hasar,
          'hasar_not', a.hasar_not, 'hasar_foto', a.hasar_foto, 'belge', a.belge, 'alis', a.alis, 'sat', a.sat, 'odeme_yontem', a.odeme_yontem,
          'musteri_karar_zaman', a.musteri_karar_zaman) from alim a where a.id = (o.veri->>'alim_id')::uuid) end)
      order by (o.durum = 'bekliyor') desc, o.created_at desc)
    from onay o left join sube sb on sb.id = o.sube_id
    where o.isletme_id = isl and (y or o.isteyen = auth.uid())
      and (o.durum = 'bekliyor' or o.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_gun, 14), 90))))), '[]'::jsonb);
end $$;

create or replace function onay_sayisi() returns int
language sql stable security definer set search_path = public as $$
  select case when yonetici_mi(aktif_isletme())
    then (select count(*)::int from onay where isletme_id = aktif_isletme() and durum = 'bekliyor')
    else (select count(*)::int from onay where isletme_id = aktif_isletme() and isteyen = auth.uid() and durum = 'bekliyor') end
$$;

-- Kasa: müşteriden cihaz alımında ödenen bedel de çıkış olarak görünür
create or replace function kasa_ozet(p_sube uuid default null, p_tarih date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme();
  t date := coalesce(p_tarih, tr_bugun());
  sonuc jsonb;
begin
  if isl is null or not yonetici_mi(isl) then raise exception 'Yetki yok'; end if;
  if p_sube is not null and not exists (select 1 from sube where id = p_sube and isletme_id = isl) then
    raise exception 'Şube bulunamadı';
  end if;
  with h as (
    select 'satis'::text as tur, s.created_at as zaman, s.ad as baslik, s.odeme_yontem as yontem,
           s.adet * s.fiyat as tutar, s.adet, s.fis, s.id, s.sube_id
    from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s where s.isletme_id = isl and s.tarih = t and s.tip = 'normal' and (p_sube is null or s.sube_id = p_sube)
    union all
    select 'iade', s.created_at, s.ad, s.odeme_yontem, -(s.adet * s.fiyat), s.adet, s.fis, s.id, s.sube_id
    from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s where s.isletme_id = isl and s.tarih = t and s.tip = 'iade' and (p_sube is null or s.sube_id = p_sube)
    union all
    select 'ek_gelir', e.created_at, coalesce(nullif(btrim(e.aciklama), ''), 'Ek gelir'), e.odeme_yontem, e.tutar, null, null, e.id, e.sube_id
    from ek_gelir e where e.isletme_id = isl and e.tarih = t and (p_sube is null or e.sube_id = p_sube)
    union all
    select 'gider', g.created_at, coalesce(nullif(btrim(g.kategori), ''), nullif(btrim(g.aciklama), ''), 'Gider'), g.odeme_yontem,
           -g.tutar, null, null, g.id, g.sube_id
    from gider g where g.isletme_id = isl and g.tarih = t and (p_sube is null or g.sube_id = p_sube)
    union all
    select 'servis', coalesce(sv.created_at, now()), concat_ws(' · ', coalesce(nullif(sv.cihaz, ''), 'Servis'), nullif(sv.musteri, '')),
           coalesce(nullif(sv.odeme_yontem, ''), 'Nakit'), coalesce(sv.odeme, sv.ucret, 0), null, null, sv.id, sv.sube_id
    from servis sv where sv.isletme_id = isl and sv.odeme_tarih = t and coalesce(sv.odeme, sv.ucret, 0) > 0
      and (p_sube is null or sv.sube_id = p_sube)
    union all
    select 'alim', a.belge_zaman, concat_ws(' · ', 'Cihaz alımı', concat_ws(' ', nullif(a.marka, ''), a.model), a.musteri_ad),
           a.odeme_yontem, -a.alis, 1, null, a.id, a.sube_id
    from alim a where a.isletme_id = isl and a.belge is not null and a.durum <> 'iptal'
      and (a.belge_zaman at time zone 'Europe/Istanbul')::date = t and (p_sube is null or a.sube_id = p_sube)
  ), y as (
    select m.y,
           coalesce(sum(h.tutar) filter (where h.tutar > 0), 0) as giris,
           coalesce(-sum(h.tutar) filter (where h.tutar < 0), 0) as cikis
    from (values ('Nakit'), ('Kart'), ('Havale')) m(y) left join h on h.yontem = m.y group by m.y
  )
  select jsonb_build_object(
    'tarih', t,
    'giris', (select jsonb_object_agg(y.y, y.giris) from y),
    'cikis', (select jsonb_object_agg(y.y, y.cikis) from y),
    'satis', (select coalesce(sum(tutar), 0) from h where tur in ('satis', 'iade')),
    'satis_fis', (select count(distinct fis) from h where tur = 'satis'),
    'iade', (select coalesce(-sum(tutar), 0) from h where tur = 'iade'),
    'servis', (select coalesce(sum(tutar), 0) from h where tur = 'servis'),
    'ek_gelir', (select coalesce(sum(tutar), 0) from h where tur = 'ek_gelir'),
    'gider', (select coalesce(-sum(tutar), 0) from h where tur = 'gider'),
    'alim', (select coalesce(-sum(tutar), 0) from h where tur = 'alim'),
    'beklenen_nakit', (select giris - cikis from y where y.y = 'Nakit'),
    'hareketler', (select coalesce(jsonb_agg(jsonb_build_object('tur', x.tur, 'zaman', x.zaman, 'baslik', x.baslik, 'yontem', x.yontem,
                     'tutar', x.tutar, 'adet', x.adet, 'fis', x.fis, 'id', x.id, 'sube', sb.ad) order by x.zaman desc), '[]'::jsonb)
                   from (select * from h order by zaman desc limit 400) x left join sube sb on sb.id = x.sube_id),
    'kapanis', case when p_sube is null then null else
                 (select jsonb_build_object('beklenen', k.beklenen, 'sayilan', k.sayilan, 'fark', k.fark, 'aciklama', k.aciklama,
                                            'zaman', k.created_at, 'kapatan', coalesce(u.ad, u.kullanici, ''))
                  from kasa_kapanis k left join uye u on u.user_id = k.kapatan and u.isletme_id = isl
                  where k.sube_id = p_sube and k.tarih = t) end,
    'subeler', case when p_sube is not null then null else
                 (select coalesce(jsonb_agg(jsonb_build_object('id', sb.id, 'ad', sb.ad,
                     'beklenen_nakit', coalesce((select sum(h2.tutar) from h h2 where h2.sube_id = sb.id and h2.yontem = 'Nakit'), 0),
                     'kapanis', (select jsonb_build_object('sayilan', k.sayilan, 'fark', k.fark) from kasa_kapanis k
                                 where k.sube_id = sb.id and k.tarih = t)) order by sb.created_at), '[]'::jsonb)
                  from sube sb where sb.isletme_id = isl and sb.aktif) end
  ) into sonuc;
  return sonuc;
end $$;

-- 4) Asistan: müdür ve personel kullanır; para bilgisi verilmez -------------------------------------------
create or replace function ai_hak(p_tur text default 'soru') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme();
  i isletme%rowtype;
  s sistem%rowtype;
  lim int;
  n int;
  gn int;
  deneme boolean;
  bu_ay date := date_trunc('month', current_date)::date;
begin
  if isl is null or not exists (select 1 from uye u where u.isletme_id = isl and u.user_id = auth.uid() and u.aktif
                                and u.rol in ('yonetici', 'mudur', 'personel')) then
    raise exception 'Asistanı bu hesap kullanamaz';
  end if;
  if not rol_mi(isl, array['yonetici', 'mudur', 'personel']) then
    raise exception 'Aboneliğin sona erdiği için asistan kapalı. Paket ve ödeme sayfasından ödeme bildirebilirsin.';
  end if;
  select * into i from isletme where id = isl;
  select * into s from sistem where id = 1;
  if p_tur = 'kampanya' and not (i.plan = 'pro' or i.ucretsiz) then raise exception 'Kampanyalar Pro pakette'; end if;
  if p_tur = 'kampanya' and not rol_mi(isl, array['yonetici', 'mudur']) then raise exception 'Kampanyaları yönetici ve mağaza müdürü hazırlar'; end if;
  lim := case when i.plan = 'pro' or i.ucretsiz then s.ai_pro else s.ai_standart end;
  deneme := not i.ucretsiz and (i.odeme_bitis is null or i.odeme_bitis < current_date);
  if deneme and s.ai_deneme is not null then lim := least(lim, s.ai_deneme); end if;
  insert into ai_kullanim as k (isletme_id, ay, sayi) values (isl, bu_ay, 1)
  on conflict (isletme_id, ay) do update set sayi = k.sayi + 1
  returning k.sayi into n;
  if n > lim then
    if deneme and s.ai_deneme is not null and s.ai_deneme < (case when i.plan = 'pro' or i.ucretsiz then s.ai_pro else s.ai_standart end) then
      raise exception 'Deneme süresindeki asistan hakkın doldu (% soru). Ödeme yapınca hakkın artar.', lim;
    end if;
    raise exception 'Bu ayki asistan hakkın doldu (% soru). Gelecek ay yenilenir.', lim;
  end if;
  if s.ai_gunluk is not null then
    insert into ai_gunluk_sayac as g (gun, sayi) values (tr_bugun(), 1)
    on conflict (gun) do update set sayi = g.sayi + 1
    returning g.sayi into gn;
    if gn > s.ai_gunluk then raise exception 'Asistan bugün çok yoğun. Lütfen yarın tekrar dene.'; end if;
  end if;
  return jsonb_build_object('kalan', lim - n, 'limit', lim, 'pro', i.plan = 'pro' or i.ucretsiz, 'deneme', deneme);
end $$;

create or replace function ai_durum() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme();
  i isletme%rowtype;
  s sistem%rowtype;
  lim int;
  n int;
  deneme boolean;
begin
  if isl is null or not exists (select 1 from uye u where u.isletme_id = isl and u.user_id = auth.uid() and u.aktif
                                and u.rol in ('yonetici', 'mudur', 'personel')) then
    raise exception 'Yetki yok';
  end if;
  select * into i from isletme where id = isl;
  select * into s from sistem where id = 1;
  lim := case when i.plan = 'pro' or i.ucretsiz then s.ai_pro else s.ai_standart end;
  deneme := not i.ucretsiz and (i.odeme_bitis is null or i.odeme_bitis < current_date);
  if deneme and s.ai_deneme is not null then lim := least(lim, s.ai_deneme); end if;
  select coalesce(sum(k.sayi), 0) into n from ai_kullanim k where k.isletme_id = isl and k.ay = date_trunc('month', current_date)::date;
  return jsonb_build_object('kullanilan', n, 'limit', lim, 'kalan', greatest(lim - n, 0), 'pro', i.plan = 'pro' or i.ucretsiz, 'deneme', deneme);
end $$;

-- Yöneticinin asistan verisi (tam)
create or replace function ai_veri_yonetici() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  isl uuid := aktif_isletme();
  bugun date := (now() at time zone 'Europe/Istanbul')::date;
  ay_bas date := date_trunc('month', (now() at time zone 'Europe/Istanbul'))::date;
  gecen_ay_bas date := (date_trunc('month', (now() at time zone 'Europe/Istanbul')) - interval '1 month')::date;
  sonuc jsonb;
begin
  if isl is null or not yonetici_mi(isl) then raise exception 'Yetki yok'; end if;
  select jsonb_build_object(
    'bugun', bugun,
    'isletme', (select jsonb_build_object(
        'ad', i.ad, 'sektor', i.sektor, 'paket', case when i.plan = 'pro' or i.ucretsiz then 'Pro' else 'Standart' end,
        'telefon', i.ayarlar->'site'->>'telefon', 'whatsapp', i.ayarlar->'site'->>'whatsapp',
        'adres', i.ayarlar->'site'->>'adres', 'calisma_saatleri', i.ayarlar->'site'->>'saat')
      from isletme i where i.id = isl),
    'satis', (select jsonb_build_object(
        'bugun', jsonb_build_object('islem', count(*) filter (where s.tarih = bugun and s.yon = 1),
                   'adet', coalesce(sum((s.yon * s.adet)) filter (where s.tarih = bugun), 0),
                   'ciro', coalesce(sum((s.yon * s.adet) * s.fiyat) filter (where s.tarih = bugun), 0),
                   'kar', coalesce(sum((s.yon * s.adet) * (s.fiyat - s.maliyet)) filter (where s.tarih = bugun), 0)),
        'son_7_gun', jsonb_build_object('adet', coalesce(sum((s.yon * s.adet)) filter (where s.tarih > bugun - 7), 0),
                   'ciro', coalesce(sum((s.yon * s.adet) * s.fiyat) filter (where s.tarih > bugun - 7), 0),
                   'kar', coalesce(sum((s.yon * s.adet) * (s.fiyat - s.maliyet)) filter (where s.tarih > bugun - 7), 0)),
        'son_30_gun', jsonb_build_object('adet', coalesce(sum((s.yon * s.adet)) filter (where s.tarih > bugun - 30), 0),
                   'ciro', coalesce(sum((s.yon * s.adet) * s.fiyat) filter (where s.tarih > bugun - 30), 0),
                   'kar', coalesce(sum((s.yon * s.adet) * (s.fiyat - s.maliyet)) filter (where s.tarih > bugun - 30), 0)),
        'bu_ay', jsonb_build_object('adet', coalesce(sum((s.yon * s.adet)) filter (where s.tarih >= ay_bas), 0),
                   'ciro', coalesce(sum((s.yon * s.adet) * s.fiyat) filter (where s.tarih >= ay_bas), 0),
                   'kar', coalesce(sum((s.yon * s.adet) * (s.fiyat - s.maliyet)) filter (where s.tarih >= ay_bas), 0)),
        'gecen_ay', jsonb_build_object('adet', coalesce(sum((s.yon * s.adet)) filter (where s.tarih >= gecen_ay_bas and s.tarih < ay_bas), 0),
                   'ciro', coalesce(sum((s.yon * s.adet) * s.fiyat) filter (where s.tarih >= gecen_ay_bas and s.tarih < ay_bas), 0),
                   'kar', coalesce(sum((s.yon * s.adet) * (s.fiyat - s.maliyet)) filter (where s.tarih >= gecen_ay_bas and s.tarih < ay_bas), 0)))
      from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s where s.isletme_id = isl and s.tarih >= gecen_ay_bas),
    'odeme_yontemi_son_30_gun', (select coalesce(jsonb_object_agg(x.odeme_yontem, x.tutar), '{}'::jsonb) from (
        select s.odeme_yontem, sum((s.yon * s.adet) * s.fiyat) as tutar from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s
        where s.isletme_id = isl and s.tarih > bugun - 30 group by s.odeme_yontem) x),
    'en_cok_satan_son_30_gun', (select coalesce(jsonb_agg(to_jsonb(x) order by x.adet desc), '[]'::jsonb) from (
        select coalesce(nullif(s.ad, ''), 'Adsız ürün') as urun, sum((s.yon * s.adet)) as adet, sum((s.yon * s.adet) * s.fiyat) as ciro,
               sum((s.yon * s.adet) * (s.fiyat - s.maliyet)) as kar
        from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s where s.isletme_id = isl and s.tarih > bugun - 30
        group by 1 order by 2 desc limit 10) x),
    'gunluk_ciro_son_14_gun', (select coalesce(jsonb_agg(jsonb_build_object('tarih', g.gun, 'ciro', coalesce(t.ciro, 0)) order by g.gun), '[]'::jsonb)
      from (select generate_series(bugun - 13, bugun, interval '1 day')::date as gun) g
      left join (select s.tarih, sum((s.yon * s.adet) * s.fiyat) as ciro from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s
                 where s.isletme_id = isl and s.tarih > bugun - 14 group by s.tarih) t on t.tarih = g.gun),
    'stok', (select jsonb_build_object('cesit', count(*), 'toplam_adet', coalesce(sum(st.adet), 0),
               'alis_degeri', coalesce(sum(st.adet * st.alis), 0), 'satis_degeri', coalesce(sum(st.adet * st.sat), 0),
               'tukenen', count(*) filter (where st.adet <= 0), 'azalan', count(*) filter (where st.adet > 0 and st.adet <= st.kritik))
      from stok st where st.isletme_id = isl),
    'azalan_veya_tukenen_urunler', (select coalesce(jsonb_agg(jsonb_build_object(
          'urun', concat_ws(' ', st.marka, st.ad), 'sube', (select sb.ad from sube sb where sb.id = st.sube_id),
          'stok', st.adet, 'kritik_seviye', st.kritik,
          'son_30_gun_satis', (select coalesce(sum((s.yon * s.adet)), 0) from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s
                               where s.isletme_id = isl and s.sid = st.id and s.tarih > bugun - 30))), '[]'::jsonb)
      from (select * from stok where isletme_id = isl and adet <= kritik order by adet limit 25) st),
    'satilmayan_urun_sayisi_son_60_gun', (select count(*) from stok st where st.isletme_id = isl and st.adet > 0
        and not exists (select 1 from (select x.*, case when x.tip = 'iade' then -1 else 1 end as yon from satis x) s where s.isletme_id = isl and s.sid = st.id and s.tarih > bugun - 60)),
    'teknik_servis', (select jsonb_build_object(
        'acik', count(*) filter (where sv.durum <> 'Teslim edildi'),
        'beklemede', count(*) filter (where sv.durum = 'Beklemede'),
        'tamirde', count(*) filter (where sv.durum = 'Tamirde'),
        'teslime_hazir', count(*) filter (where sv.durum = 'Hazır'),
        'bu_ay_teslim', count(*) filter (where sv.durum = 'Teslim edildi' and sv.teslim >= ay_bas),
        'bu_ay_servis_geliri', coalesce(sum(coalesce(sv.odeme, sv.ucret)) filter (where sv.durum = 'Teslim edildi' and sv.teslim >= ay_bas), 0),
        'bu_ay_parca_maliyeti', coalesce(sum(sv.maliyet) filter (where sv.durum = 'Teslim edildi' and sv.teslim >= ay_bas), 0))
      from servis sv where sv.isletme_id = isl),
    'gider', (select jsonb_build_object(
        'bu_ay', coalesce(sum(g.tutar) filter (where g.tarih >= ay_bas), 0),
        'gecen_ay', coalesce(sum(g.tutar) filter (where g.tarih >= gecen_ay_bas and g.tarih < ay_bas), 0))
      from gider g where g.isletme_id = isl and g.tarih >= gecen_ay_bas),
    'gider_kategorileri_bu_ay', (select coalesce(jsonb_object_agg(x.kategori, x.tutar), '{}'::jsonb) from (
        select coalesce(nullif(g.kategori, ''), 'Diğer') as kategori, sum(g.tutar) as tutar
        from gider g where g.isletme_id = isl and g.tarih >= ay_bas group by 1) x),
    'ek_gelir_bu_ay', (select coalesce(sum(e.tutar), 0) from ek_gelir e where e.isletme_id = isl and e.tarih >= ay_bas),
    'kasa_kapanis_son_7_gun', (select coalesce(jsonb_agg(jsonb_build_object('tarih', kk.tarih,
          'sube', (select sb.ad from sube sb where sb.id = kk.sube_id), 'beklenen', kk.beklenen,
          'sayilan', kk.sayilan, 'fark', kk.fark) order by kk.tarih desc), '[]'::jsonb)
      from kasa_kapanis kk where kk.isletme_id = isl and kk.tarih > bugun - 7),
    'musteri', (select jsonb_build_object('toplam', count(*), 'ileti_izni_olan', count(*) filter (where m.ileti_izni))
      from musteri m where m.isletme_id = isl),
    'ekip_kisi_sayisi', (select count(*) from uye u where u.isletme_id = isl and u.aktif),
    'subeler', ai_sube_ozet(isl)
  ) into sonuc;
  return sonuc;
end $$;

-- Müdür ve personel için asistan verisi: stok, ürünler (satış fiyatıyla), teknik servis; para bilgisi yok
create or replace function ai_veri_ekip(p_isl uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'erisim_notu', 'Soran kişi ' || case u.rol when 'mudur' then 'mağaza müdürü' else 'personel' end ||
      '. Ciro, kâr, kazanç, gelir, gider, kasa, satış tutarları, ödemeler ve raporlar ona kapalı; bu veriler sana da verilmedi. ' ||
      'Bu konularda soru gelirse tahmin yürütme, nazikçe "Bu bilgiyi görme yetkin yok; işletme sahibine sorabilirsin." de ' ||
      've stok, ürünler ya da teknik servis konusunda yardım teklif et.',
    'kullanici', jsonb_build_object('rol', case u.rol when 'mudur' then 'Mağaza müdürü' else 'Personel' end, 'ad', coalesce(u.ad, u.kullanici)),
    'bugun', tr_bugun(),
    'isletme', jsonb_build_object('ad', i.ad, 'sektor', i.sektor, 'telefon', i.ayarlar->'site'->>'telefon',
                                  'adres', i.ayarlar->'site'->>'adres', 'calisma_saatleri', i.ayarlar->'site'->>'saat'),
    'stok', (select jsonb_build_object('cesit', count(*), 'toplam_adet', coalesce(sum(st.adet), 0),
               'tukenen', count(*) filter (where st.adet <= 0), 'azalan', count(*) filter (where st.adet > 0 and st.adet <= st.kritik))
             from stok st where st.isletme_id = p_isl and sube_erisim(p_isl, st.sube_id)),
    'urunler', (select coalesce(jsonb_agg(jsonb_build_object('urun', stok_ad(st), 'kategori', st.tur, 'adet', st.adet, 'satis_fiyati', st.sat,
                   'sube', (select sb.ad from sube sb where sb.id = st.sube_id)) order by st.adet desc), '[]'::jsonb)
                from (select * from stok where isletme_id = p_isl and sube_erisim(p_isl, sube_id) order by created_at desc limit 150) st),
    'azalan_veya_tukenen_urunler', (select coalesce(jsonb_agg(jsonb_build_object('urun', stok_ad(st), 'stok', st.adet, 'kritik_seviye', st.kritik)), '[]'::jsonb)
                from (select * from stok where isletme_id = p_isl and sube_erisim(p_isl, sube_id) and adet <= kritik order by adet limit 25) st),
    'son_30_gun_satilan_adet', (select coalesce(jsonb_agg(jsonb_build_object('urun', x.ad, 'adet', x.n) order by x.n desc), '[]'::jsonb) from (
                select coalesce(nullif(s.ad, ''), 'Adsız ürün') as ad, sum(case when s.tip = 'iade' then -s.adet else s.adet end) as n
                from satis s where s.isletme_id = p_isl and s.tarih > tr_bugun() - 30 and sube_erisim(p_isl, s.sube_id)
                group by 1 having sum(case when s.tip = 'iade' then -s.adet else s.adet end) > 0 order by 2 desc limit 15) x),
    'teknik_servis', (select jsonb_build_object('acik', count(*) filter (where sv.durum <> 'Teslim edildi'),
                'beklemede', count(*) filter (where sv.durum = 'Beklemede'), 'tamirde', count(*) filter (where sv.durum = 'Tamirde'),
                'teslime_hazir', count(*) filter (where sv.durum = 'Hazır'))
              from servis sv where sv.isletme_id = p_isl and sube_erisim(p_isl, sv.sube_id)),
    'onay_bekleyen_islemlerim', (select count(*) from onay o where o.isletme_id = p_isl and o.isteyen = auth.uid() and o.durum = 'bekliyor'),
    'subeler', (select coalesce(jsonb_agg(sb.ad order by sb.created_at), '[]'::jsonb) from sube sb where sb.isletme_id = p_isl and sb.aktif))
  from uye u join isletme i on i.id = u.isletme_id
  where u.isletme_id = p_isl and u.user_id = auth.uid() and u.aktif
$$;

create or replace function ai_veri() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare isl uuid := aktif_isletme();
begin
  if isl is null then raise exception 'Yetki yok'; end if;
  if yonetici_mi(isl) then return ai_veri_yonetici(); end if;
  if rol_mi(isl, array['mudur', 'personel']) then return ai_veri_ekip(isl); end if;
  raise exception 'Yetki yok';
end $$;

-- 5) Fonksiyon izinleri ---------------------------------------------------------------------------------
revoke all on function rol_mi(uuid, text[]) from public, anon;
grant execute on function rol_mi(uuid, text[]) to authenticated;
revoke all on function stok_ayrilan(uuid, uuid), onay_ekle(uuid, uuid, text, jsonb, text, numeric), alim_tamamla(uuid),
  satis_isle(uuid, uuid, jsonb, text, text, date, uuid, uuid), ai_veri_yonetici(), ai_veri_ekip(uuid) from public, anon, authenticated;
revoke all on function uye_rol(uuid, text), stok_ayrilanlar(), satis_iste(uuid, jsonb, text, text), urun_iste(jsonb),
  stok_giris_iste(uuid, int, numeric, text), stok_dusme_iste(uuid, int, text), alim_olustur(jsonb), alim_foto(uuid, text[]),
  alim_link_yenile(uuid), alim_belge(uuid, text), alim_iptal(uuid), onay_karar(uuid, boolean, text), onay_iptal(uuid),
  onay_listesi(int), onay_sayisi(), satis_yap(uuid, jsonb, text, text, date), ai_hak(text), ai_durum(), ai_veri(),
  calisan_bagla(text, text, text, uuid), stok_satis_hizi(uuid) from public, anon;
grant execute on function uye_rol(uuid, text), stok_ayrilanlar(), satis_iste(uuid, jsonb, text, text), urun_iste(jsonb),
  stok_giris_iste(uuid, int, numeric, text), stok_dusme_iste(uuid, int, text), alim_olustur(jsonb), alim_foto(uuid, text[]),
  alim_link_yenile(uuid), alim_belge(uuid, text), alim_iptal(uuid), onay_karar(uuid, boolean, text), onay_iptal(uuid),
  onay_listesi(int), onay_sayisi(), satis_yap(uuid, jsonb, text, text, date), ai_hak(text), ai_durum(), ai_veri(),
  calisan_bagla(text, text, text, uuid), stok_satis_hizi(uuid) to authenticated;
revoke all on function alim_bilgi(text), alim_karar(text, boolean) from public;
grant execute on function alim_bilgi(text), alim_karar(text, boolean) to anon, authenticated;
do $$ declare t text; begin
  foreach t in array array['onay', 'alim'] loop
    execute format('revoke truncate, references, trigger on table public.%I from anon, authenticated', t);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Kontrol
select 'Güncelleme 5 kuruldu' as durum, (select count(*) from uye) as ekip_kisi, (select count(*) from onay) as onay_kaydi;
