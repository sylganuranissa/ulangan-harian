-- ============================================================
-- supabase.sql - Setup database Aplikasi Ulangan Harian
--
-- Cara pakai: Supabase Dashboard → SQL Editor → paste semua → Run.
-- Aman dijalankan ulang (idempotent).
--
-- Keamanan:
--   * Tabel soal_*/config diblokir dari akses langsung anon.
--     Kunci jawaban & ADMIN_PIN hanya bisa diakses lewat RPC.
--   * Tabel siswa/jawaban/log_aktivitas terbuka untuk anon
--     (model auth NIS+token sama seperti versi GAS).
-- ============================================================

-- ======================== 1. TABEL ========================

create table if not exists config (
  key   text primary key,
  value text not null default ''
);

create table if not exists siswa (
  id            uuid primary key default gen_random_uuid(),
  nis           text not null unique,
  nama          text not null default '',
  kelas         text not null default '',
  paket_soal    text not null default '',
  status        text not null default 'Belum Mulai',
  token_aktif   text not null default '',
  waktu_mulai   timestamptz,
  waktu_selesai timestamptz,
  skor          integer
);

create table if not exists soal_paket_a (
  id         uuid primary key default gen_random_uuid(),
  no         integer not null unique,
  pertanyaan text not null default '',
  a          text not null default '',
  b          text not null default '',
  c          text not null default '',
  d          text not null default '',
  e          text not null default '',
  kunci      text not null default '',
  poin       integer not null default 10
);

create table if not exists soal_paket_b (
  id         uuid primary key default gen_random_uuid(),
  no         integer not null unique,
  pertanyaan text not null default '',
  a          text not null default '',
  b          text not null default '',
  c          text not null default '',
  d          text not null default '',
  e          text not null default '',
  kunci      text not null default '',
  poin       integer not null default 10
);

create table if not exists jawaban (
  id        uuid primary key default gen_random_uuid(),
  nis       text not null,
  no_soal   integer not null,
  paket     text not null default '',
  jawaban   text not null default '',
  timestamp timestamptz not null default now()
);

alter table jawaban drop constraint if exists jawaban_nis_no_soal_key;
alter table jawaban add constraint jawaban_nis_no_soal_key unique (nis, no_soal);

create table if not exists log_aktivitas (
  id        uuid primary key default gen_random_uuid(),
  nis       text not null default '',
  event     text not null default '',
  timestamp timestamptz not null default now(),
  detail    text not null default ''
);

-- ======================== 2. RLS ========================

alter table config        enable row level security;
alter table siswa         enable row level security;
alter table soal_paket_a  enable row level security;
alter table soal_paket_b  enable row level security;
alter table jawaban       enable row level security;
alter table log_aktivitas enable row level security;

drop policy if exists "anon_all_siswa"   on siswa;
drop policy if exists "anon_all_jawaban" on jawaban;
drop policy if exists "anon_all_log"     on log_aktivitas;

create policy "anon_all_siswa" on siswa for all
  to anon using (true) with check (true);

create policy "anon_all_jawaban" on jawaban for all
  to anon using (true) with check (true);

create policy "anon_all_log" on log_aktivitas for all
  to anon using (true) with check (true);

-- soal_* & config: sengaja TANPA policy untuk anon.
-- Akses hanya lewat SECURITY DEFINER RPC di bawah.

-- ======================== 3. RPC (SECURITY DEFINER) ========================

-- Helper: durasi dari config
create or replace function _durasi_menit() returns integer
language sql security definer as $$
  select coalesce((select value::integer from config where key = 'DURASI_MENIT'), 30);
$$;

-- Helper: judul dari config
create or replace function _judul_ulangan() returns text
language sql security definer as $$
  select coalesce((select value from config where key = 'JUDUL_ULANGAN'), 'Ulangan Harian');
$$;

-- 3a. get_soal_siswa: soal TANPA kunci + jawaban tersimpan
create or replace function get_soal_siswa(nis_param text)
returns jsonb language plpgsql security definer as $$
declare
  v_siswa   siswa%rowtype;
  v_paket   text;
  v_soal    jsonb;
  v_jawaban jsonb;
begin
  select * into v_siswa from siswa where nis = nis_param limit 1;
  if not found then
    return jsonb_build_object('error', 'Siswa tidak ditemukan.');
  end if;

  v_paket := v_siswa.paket_soal;
  if v_paket is null or v_paket = '' then
    v_paket := case when random() < 0.5 then 'A' else 'B' end;
    update siswa set paket_soal = v_paket where id = v_siswa.id;
    insert into log_aktivitas (nis, event, detail) values (nis_param, 'Login', 'Paket ' || v_paket || ' ditetapkan');
  end if;

  if v_paket = 'B' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'No', no, 'Pertanyaan', pertanyaan,
      'A', a, 'B', b, 'C', c, 'D', d, 'E', e, 'Poin', poin
    ) order by no), '[]'::jsonb) into v_soal from soal_paket_b;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'No', no, 'Pertanyaan', pertanyaan,
      'A', a, 'B', b, 'C', c, 'D', d, 'E', e, 'Poin', poin
    ) order by no), '[]'::jsonb) into v_soal from soal_paket_a;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('No', no_soal, 'Jawaban', jawaban) order by no_soal),
                  '[]'::jsonb)
    into v_jawaban
    from jawaban where nis = nis_param;

  return jsonb_build_object(
    'paket',     v_paket,
    'soal',      v_soal,
    'jawaban',   v_jawaban,
    'judul',     _judul_ulangan(),
    'durasi',    _durasi_menit(),
    'waktuMulai', case when v_siswa.waktu_mulai is null then null
                       else (extract(epoch from v_siswa.waktu_mulai) * 1000)::bigint end
  );
end;
$$;

-- 3b. validasi_token_siswa: cek token master / token aktif, mulai sesi
create or replace function validasi_token_siswa(nis_param text, token_param text)
returns jsonb language plpgsql security definer as $$
declare
  v_siswa  siswa%rowtype;
  v_master text;
begin
  select * into v_siswa from siswa where nis = nis_param limit 1;
  if not found then
    return jsonb_build_object('valid', false, 'reason', 'Siswa tidak ditemukan.');
  end if;

  if v_siswa.status = 'Selesai' then
    return jsonb_build_object('valid', false, 'reason', 'Kamu sudah menyelesaikan ulangan.');
  end if;

  select value into v_master from config where key = 'TOKEN_MASTER';

  if token_param = v_master and v_siswa.status = 'Belum Mulai' then
    update siswa set status = 'Mengerjakan',
                     waktu_mulai = coalesce(waktu_mulai, now())
      where id = v_siswa.id;
    insert into log_aktivitas (nis, event, detail) values (nis_param, 'Mulai', 'Login dengan token master');
    select * into v_siswa from siswa where id = v_siswa.id;
    return jsonb_build_object('valid', true, 'durasi', _durasi_menit(),
      'waktuMulai', (extract(epoch from v_siswa.waktu_mulai) * 1000)::bigint,
      'paket', coalesce(nullif(v_siswa.paket_soal, ''), 'A'));
  end if;

  if token_param <> '' and token_param = v_siswa.token_aktif
     and v_siswa.status in ('Terkunci', 'Belum Mulai') then
    update siswa set status = 'Mengerjakan',
                     waktu_mulai = coalesce(waktu_mulai, now())
      where id = v_siswa.id;
    insert into log_aktivitas (nis, event, detail) values (nis_param, 'Mulai', 'Login dengan token aktif');
    select * into v_siswa from siswa where id = v_siswa.id;
    return jsonb_build_object('valid', true, 'durasi', _durasi_menit(),
      'waktuMulai', (extract(epoch from v_siswa.waktu_mulai) * 1000)::bigint,
      'paket', coalesce(nullif(v_siswa.paket_soal, ''), 'A'));
  end if;

  return jsonb_build_object('valid', false, 'reason', 'Token salah. Cek kembali token dari gurumu.');
end;
$$;

-- 3c. submit_ulangan_siswa: hitung skor server-side, update status
create or replace function submit_ulangan_siswa(nis_param text)
returns jsonb language plpgsql security definer as $$
declare
  v_siswa     siswa%rowtype;
  v_paket     text;
  v_total     integer := 0;
  v_earned    integer := 0;
  v_score     integer := 0;
  v_count     integer := 0;
  v_row       record;
  v_benar     integer := 0;
begin
  select * into v_siswa from siswa where nis = nis_param limit 1;
  if not found then
    return jsonb_build_object('skor', 0, 'benar', 0, 'totalSoal', 0, 'paket', 'A',
      'waktuSelesai', (extract(epoch from now()) * 1000)::bigint);
  end if;

  v_paket := coalesce(nullif(v_siswa.paket_soal, ''), 'A');

  if v_paket = 'B' then
    for v_row in select * from soal_paket_b loop
      v_total := v_total + v_row.poin;  v_count := v_count + 1;
      if exists (select 1 from jawaban
                 where nis = nis_param and no_soal = v_row.no and jawaban = v_row.kunci) then
        v_earned := v_earned + v_row.poin;
      end if;
    end loop;
  else
    for v_row in select * from soal_paket_a loop
      v_total := v_total + v_row.poin;  v_count := v_count + 1;
      if exists (select 1 from jawaban
                 where nis = nis_param and no_soal = v_row.no and jawaban = v_row.kunci) then
        v_earned := v_earned + v_row.poin;
      end if;
    end loop;
  end if;

  if v_total > 0 then
    v_score := round((v_earned::numeric / v_total) * 100)::integer;
    v_benar := round(v_earned::numeric / (v_total::numeric / v_count))::integer;
  end if;

  update siswa set status = 'Selesai', waktu_selesai = now(), skor = v_score
    where id = v_siswa.id;

  insert into log_aktivitas (nis, event, detail) values (nis_param, 'Submit', 'Skor: ' || v_score);

  return jsonb_build_object('skor', v_score, 'benar', v_benar, 'totalSoal', v_count,
    'paket', v_paket, 'waktuSelesai', (extract(epoch from now()) * 1000)::bigint);
end;
$$;

-- 3d. lock_ulangan_siswa: set Terkunci + generate token baru
create or replace function lock_ulangan_siswa(nis_param text)
returns jsonb language plpgsql security definer as $$
declare
  v_siswa siswa%rowtype;
  v_token text := '';
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i int;
begin
  select * into v_siswa from siswa where nis = nis_param limit 1;
  if not found or v_siswa.status = 'Selesai' then
    return jsonb_build_object('locked', false);
  end if;

  for i in 1..6 loop
    v_token := v_token || substr(v_chars, floor(random() * length(v_chars))::int + 1, 1);
  end loop;

  update siswa set status = 'Terkunci', token_aktif = v_token where id = v_siswa.id;
  insert into log_aktivitas (nis, event, detail) values (nis_param, 'Tab_Switch_Terdeteksi', 'Berpindah tab/window');
  insert into log_aktivitas (nis, event, detail) values (nis_param, 'Terkunci', 'Token baru: ' || v_token);

  return jsonb_build_object('locked', true);
end;
$$;

-- 3e. request_unlock_siswa: validasi token baru, kembali Mengerjakan
create or replace function request_unlock_siswa(nis_param text, token_param text)
returns jsonb language plpgsql security definer as $$
declare
  v_siswa siswa%rowtype;
begin
  select * into v_siswa from siswa where nis = nis_param limit 1;
  if not found then
    return jsonb_build_object('valid', false, 'reason', 'Siswa tidak ditemukan.');
  end if;

  if v_siswa.status = 'Terkunci' and token_param = v_siswa.token_aktif then
    update siswa set status = 'Mengerjakan' where id = v_siswa.id;
    insert into log_aktivitas (nis, event, detail) values (nis_param, 'Lanjut_Mengerjakan', 'Unlock dengan token baru');
    return jsonb_build_object('valid', true, 'durasi', _durasi_menit(),
      'waktuMulai', case when v_siswa.waktu_mulai is null then null
                         else (extract(epoch from v_siswa.waktu_mulai) * 1000)::bigint end,
      'paket', coalesce(nullif(v_siswa.paket_soal, ''), 'A'));
  end if;

  return jsonb_build_object('valid', false, 'reason', 'Token salah. Minta token baru ke gurumu.');
end;
$$;

-- 3f. cek_pin_admin: validasi PIN guru (ADMIN_PIN tidak pernah keluar)
create or replace function cek_pin_admin(pin_param text)
returns jsonb language sql security definer as $$
  select jsonb_build_object('valid',
    pin_param = (select value from config where key = 'ADMIN_PIN'));
$$;

-- 3g. get_config_siswa: config tanpa ADMIN_PIN & TOKEN_MASTER
create or replace function get_config_siswa()
returns jsonb language sql security definer as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from config where key in ('JUDUL_ULANGAN', 'DURASI_MENIT', 'ULANGAN_AKTIF');
$$;

-- 3h. get_config_guru: config lengkap (dashboard guru)
create or replace function get_config_guru()
returns jsonb language sql security definer as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from config;
$$;

-- 3i. simpan_config_guru: upsert pasangan key/value
create or replace function simpan_config_guru(data jsonb)
returns jsonb language plpgsql security definer as $$
declare k text; v text;
begin
  for k, v in select * from jsonb_each_text(data) loop
    insert into config (key, value) values (k, v)
      on conflict (key) do update set value = excluded.value;
  end loop;
  return jsonb_build_object('ok', true);
end;
$$;

-- 3j. get_soal_guru: soal LENGKAP dengan kunci (khusus dashboard guru)
create or replace function get_soal_guru(paket_param text)
returns jsonb language sql security definer as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'No', no, 'Pertanyaan', pertanyaan,
    'A', a, 'B', b, 'C', c, 'D', d, 'E', e,
    'Kunci', kunci, 'Poin', poin
  ) order by no), '[]'::jsonb)
  from (select * from soal_paket_a where paket_param <> 'B'
        union all
        select * from soal_paket_b where paket_param = 'B') t;
$$;

-- 3k. simpan_soal_guru: update (idx>=0) atau insert soal baru
create or replace function simpan_soal_guru(
  paket_param text, idx_param int default -1,
  pertanyaan_param text default '', a_param text default '', b_param text default '',
  c_param text default '', d_param text default '', e_param text default '',
  kunci_param text default '', poin_param int default 10
)
returns jsonb language plpgsql security definer as $$
declare v_id uuid; v_no int;
begin
  if paket_param = 'B' then
    if idx_param >= 0 then
      select id into v_id from (
        select id, row_number() over (order by no) rn from soal_paket_b) s
        where rn = idx_param + 1;
      if v_id is null then return jsonb_build_object('ok', false, 'reason', 'Soal tidak ditemukan.'); end if;
      update soal_paket_b set pertanyaan = pertanyaan_param, a = a_param, b = b_param,
        c = c_param, d = d_param, e = e_param, kunci = kunci_param, poin = poin_param
        where id = v_id;
    else
      select coalesce(max(no), 0) + 1 into v_no from soal_paket_b;
      insert into soal_paket_b (no, pertanyaan, a, b, c, d, e, kunci, poin)
        values (v_no, pertanyaan_param, a_param, b_param, c_param, d_param, e_param, kunci_param, poin_param);
    end if;
  else
    if idx_param >= 0 then
      select id into v_id from (
        select id, row_number() over (order by no) rn from soal_paket_a) s
        where rn = idx_param + 1;
      if v_id is null then return jsonb_build_object('ok', false, 'reason', 'Soal tidak ditemukan.'); end if;
      update soal_paket_a set pertanyaan = pertanyaan_param, a = a_param, b = b_param,
        c = c_param, d = d_param, e = e_param, kunci = kunci_param, poin = poin_param
        where id = v_id;
    else
      select coalesce(max(no), 0) + 1 into v_no from soal_paket_a;
      insert into soal_paket_a (no, pertanyaan, a, b, c, d, e, kunci, poin)
        values (v_no, pertanyaan_param, a_param, b_param, c_param, d_param, e_param, kunci_param, poin_param);
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- 3l. hapus_soal_guru: hapus soal berdasarkan urutan tampil (idx)
create or replace function hapus_soal_guru(paket_param text, idx_param int)
returns jsonb language plpgsql security definer as $$
declare v_id uuid;
begin
  if paket_param = 'B' then
    select id into v_id from (select id, row_number() over (order by no) rn from soal_paket_b) s
      where rn = idx_param + 1;
    delete from soal_paket_b where id = v_id;
  else
    select id into v_id from (select id, row_number() over (order by no) rn from soal_paket_a) s
      where rn = idx_param + 1;
    delete from soal_paket_a where id = v_id;
  end if;
  return jsonb_build_object('ok', v_id is not null);
end;
$$;

-- 3m. toggle_ulangan_guru: YA <-> TIDAK
create or replace function toggle_ulangan_guru()
returns jsonb language plpgsql security definer as $$
declare v text;
begin
  select value into v from config where key = 'ULANGAN_AKTIF';
  v := case when v = 'YA' then 'TIDAK' else 'YA' end;
  insert into config (key, value) values ('ULANGAN_AKTIF', v)
    on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true, 'value', v);
end;
$$;

-- 3n. generate_token_siswa: token baru untuk satu siswa
create or replace function generate_token_siswa(nis_param text)
returns jsonb language plpgsql security definer as $$
declare v_token text := ''; v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  for i in 1..6 loop
    v_token := v_token || substr(v_chars, floor(random() * length(v_chars))::int + 1, 1);
  end loop;
  update siswa set token_aktif = v_token where nis = nis_param;
  insert into log_aktivitas (nis, event, detail) values (nis_param, 'Generate_Ulang_Token', 'Token: ' || v_token);
  return jsonb_build_object('ok', true, 'token', v_token);
end;
$$;

-- 3o. reset_all_data: kosongkan + seed ulang (dashboard guru)
create or replace function reset_all_data()
returns jsonb language plpgsql security definer as $$
begin
  delete from jawaban;
  delete from log_aktivitas;
  delete from siswa;
  delete from soal_paket_a;
  delete from soal_paket_b;

  insert into siswa (nis, nama, kelas, paket_soal, status) values
    ('001234', 'Budi Santoso', 'XII IPA 1', 'A', 'Belum Mulai'),
    ('001235', 'Siti Aminah', 'XII IPA 1', 'B', 'Belum Mulai'),
    ('001236', 'Andi Prasetyo', 'XII IPA 2', '', 'Belum Mulai');

  insert into soal_paket_a (no, pertanyaan, a, b, c, d, e, kunci, poin) values
    (1, 'Hasil dari 12 x 8 adalah ...', '86', '96', '106', '116', '126', 'B', 10),
    (2, 'Pecahan 3/4 jika diubah ke bentuk desimal adalah ...', '0,25', '0,50', '0,75', '0,80', '1,25', 'C', 10),
    (3, 'Keliling persegi dengan panjang sisi 7 cm adalah ...', '21 cm', '28 cm', '35 cm', '49 cm', '56 cm', 'B', 10),
    (4, 'Bilangan prima antara 10 dan 20 adalah ...', '11, 13, 17, 19', '11, 12, 13', '13, 15, 17', '11, 13, 15', '12, 14, 16, 18', 'A', 10),
    (5, 'Hasil dari 144 / 12 adalah ...', '10', '11', '12', '14', '16', 'C', 10);

  insert into soal_paket_b (no, pertanyaan, a, b, c, d, e, kunci, poin) values
    (1, 'Proses tumbuhan membuat makanannya sendiri disebut ...', 'Respirasi', 'Fotosintesis', 'Transpirasi', 'Evaporasi', 'Kondensasi', 'B', 10),
    (2, 'Organ pernapasan utama pada manusia adalah ...', 'Jantung', 'Ginjal', 'Paru-paru', 'Hati', 'Lambung', 'C', 10),
    (3, 'Benda yang dapat ditarik oleh magnet disebut benda ...', 'Magnetis', 'Konduktor', 'Isolator', 'Transparan', 'Luminifer', 'A', 10),
    (4, 'Perubahan wujud dari cair menjadi gas disebut ...', 'Membeku', 'Menguap', 'Mengembun', 'Menyublim', 'Mencair', 'B', 10),
    (5, 'Planet yang dikenal sebagai planet merah adalah ...', 'Venus', 'Jupiter', 'Mars', 'Saturnus', 'Neptunus', 'C', 10);

  return jsonb_build_object('ok', true);
end;
$$;

-- ======================== 4. STORAGE (gambar soal) ========================

insert into storage.buckets (id, name, public)
values ('gambar-soal', 'gambar-soal', true)
on conflict (id) do nothing;

drop policy if exists "public_read_gambar_soal" on storage.objects;
drop policy if exists "anon_insert_gambar_soal" on storage.objects;

create policy "public_read_gambar_soal" on storage.objects for select
  using (bucket_id = 'gambar-soal');

create policy "anon_insert_gambar_soal" on storage.objects for insert
  to anon with check (bucket_id = 'gambar-soal');

-- ======================== 5. SEED DATA ========================

insert into config (key, value) values
  ('JUDUL_ULANGAN', 'Ulangan Harian Matematika & IPA'),
  ('DURASI_MENIT',  '30'),
  ('TOKEN_MASTER',  'ULANGAN2026'),
  ('ULANGAN_AKTIF', 'YA'),
  ('ADMIN_PIN',     '1234')
on conflict (key) do nothing;

insert into siswa (nis, nama, kelas, paket_soal, status) values
  ('001234', 'Budi Santoso',  'XII IPA 1', 'A', 'Belum Mulai'),
  ('001235', 'Siti Aminah',   'XII IPA 1', 'B', 'Belum Mulai'),
  ('001236', 'Andi Prasetyo', 'XII IPA 2', '',  'Belum Mulai')
on conflict (nis) do nothing;

insert into soal_paket_a (no, pertanyaan, a, b, c, d, e, kunci, poin) values
  (1, 'Hasil dari 12 x 8 adalah ...', '86', '96', '106', '116', '126', 'B', 10),
  (2, 'Pecahan 3/4 jika diubah ke bentuk desimal adalah ...', '0,25', '0,50', '0,75', '0,80', '1,25', 'C', 10),
  (3, 'Keliling persegi dengan panjang sisi 7 cm adalah ...', '21 cm', '28 cm', '35 cm', '49 cm', '56 cm', 'B', 10),
  (4, 'Bilangan prima antara 10 dan 20 adalah ...', '11, 13, 17, 19', '11, 12, 13', '13, 15, 17', '11, 13, 15', '12, 14, 16, 18', 'A', 10),
  (5, 'Hasil dari 144 / 12 adalah ...', '10', '11', '12', '14', '16', 'C', 10)
on conflict (no) do nothing;

insert into soal_paket_b (no, pertanyaan, a, b, c, d, e, kunci, poin) values
  (1, 'Proses tumbuhan membuat makanannya sendiri disebut ...', 'Respirasi', 'Fotosintesis', 'Transpirasi', 'Evaporasi', 'Kondensasi', 'B', 10),
  (2, 'Organ pernapasan utama pada manusia adalah ...', 'Jantung', 'Ginjal', 'Paru-paru', 'Hati', 'Lambung', 'C', 10),
  (3, 'Benda yang dapat ditarik oleh magnet disebut benda ...', 'Magnetis', 'Konduktor', 'Isolator', 'Transparan', 'Luminifer', 'A', 10),
  (4, 'Perubahan wujud dari cair menjadi gas disebut ...', 'Membeku', 'Menguap', 'Mengembun', 'Menyublim', 'Mencair', 'B', 10),
  (5, 'Planet yang dikenal sebagai planet merah adalah ...', 'Venus', 'Jupiter', 'Mars', 'Saturnus', 'Neptunus', 'C', 10)
on conflict (no) do nothing;
