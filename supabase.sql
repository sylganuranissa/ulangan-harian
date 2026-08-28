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

-- Kolom acak_seed untuk shuffle deterministik soal & opsi per siswa.
alter table siswa add column if not exists acak_seed integer;

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
drop policy if exists "anon_sel_siswa"   on siswa;
drop policy if exists "anon_sel_jawaban" on jawaban;
drop policy if exists "anon_ins_jawaban" on jawaban;
drop policy if exists "anon_upd_jawaban" on jawaban;
drop policy if exists "anon_sel_log"     on log_aktivitas;
drop policy if exists "anon_ins_log"     on log_aktivitas;

-- Hanya SELECT untuk anon: semua modifikasi wajib lewat RPC (SECURITY DEFINER).
create policy "anon_sel_siswa" on siswa for select
  to anon using (true);

create policy "anon_sel_jawaban" on jawaban for select
  to anon using (true);
-- INSERT + UPDATE untuk auto-save jawaban siswa (upsert).
create policy "anon_ins_jawaban" on jawaban for insert
  to anon with check (true);
create policy "anon_upd_jawaban" on jawaban for update
  to anon using (true) with check (true);

create policy "anon_sel_log" on log_aktivitas for select
  to anon using (true);
create policy "anon_ins_log" on log_aktivitas for insert
  to anon with check (true);

-- soal_* & config: sengaja TANPA policy untuk anon.
-- Akses hanya lewat SECURITY DEFINER RPC di bawah.

-- ======================== 3. RPC (SECURITY DEFINER) ========================

-- Helper: validasi PIN guru (dipakai semua RPC guru)
create or replace function _cek_pin(pin_param text) returns boolean
language sql security definer as $$
  select pin_param is not null and pin_param <> ''
     and pin_param = (select value from config where key = 'ADMIN_PIN');
$$;

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

-- Helper: acak urutan opsi A-E secara deterministik per (seed, no soal).
-- Return jsonb {"A":<isi opsi posisi 1>, "B":<posisi 2>, ...}.
create or replace function _shuffle_options(seed_param int, no_param int, a text, b text, c text, d text, e text)
returns jsonb language sql as $$
  select jsonb_object_agg(pos, txt order by ord)
  from (
    select row_number() over (order by md5(l || no_param::text || seed_param::text)) - 1 as ord, txt
    from (values ('a', a), ('b', b), ('c', c), ('d', d), ('e', e)) t(l, txt)
  ) s
  join (values (0,'A'),(1,'B'),(2,'C'),(3,'D'),(4,'E')) p(rn,pos) on s.ord = p.rn;
$$;

-- Helper: petakan huruf tampil (A-E hasil shuffle) kembali ke huruf asli (A-E).
create or replace function _unshuffle_letter(seed_param int, no_param int, jawaban text)
returns text language sql as $$
  select upper(l)
  from (
    select row_number() over (order by md5(l || no_param::text || seed_param::text)) - 1 as ord, l
    from (values ('a'),('b'),('c'),('d'),('e')) t(l)
  ) s
  join (values (0,'A'),(1,'B'),(2,'C'),(3,'D'),(4,'E')) p(rn,pos) on s.ord = p.rn
  where p.pos = jawaban;
$$;

-- 3a. get_soal_siswa: soal TANPA kunci + jawaban tersimpan
create or replace function get_soal_siswa(nis_param text)
returns jsonb language plpgsql security definer as $$
declare
  v_siswa   siswa%rowtype;
  v_paket   text;
  v_seed    int;
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

  -- Seed acak soal/opsi (deterministik per siswa; null = tanpa acak, data lama)
  v_seed := v_siswa.acak_seed;
  if v_seed is null then
    v_seed := floor(random() * 1000000)::int;
    update siswa set acak_seed = v_seed where id = v_siswa.id;
  end if;

  if v_paket = 'B' then
    select coalesce(jsonb_agg(
      jsonb_build_object('No', no, 'Pertanyaan', pertanyaan, 'Poin', poin)
      || case when v_seed is null then jsonb_build_object('A', a, 'B', b, 'C', c, 'D', d, 'E', e)
              else _shuffle_options(v_seed, no, a, b, c, d, e) end
      order by (case when v_seed is null then lpad(no::text, 8, '0') else md5(no::text || v_seed::text) end)
    ), '[]'::jsonb) into v_soal from soal_paket_b;
  else
    select coalesce(jsonb_agg(
      jsonb_build_object('No', no, 'Pertanyaan', pertanyaan, 'Poin', poin)
      || case when v_seed is null then jsonb_build_object('A', a, 'B', b, 'C', c, 'D', d, 'E', e)
              else _shuffle_options(v_seed, no, a, b, c, d, e) end
      order by (case when v_seed is null then lpad(no::text, 8, '0') else md5(no::text || v_seed::text) end)
    ), '[]'::jsonb) into v_soal from soal_paket_a;
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
  v_seed      int;
  v_total     integer := 0;
  v_earned    integer := 0;
  v_score     integer := 0;
  v_count     integer := 0;
  v_row       record;
  v_benar     integer := 0;
  v_jwb       text;
  v_orig      text;
begin
  select * into v_siswa from siswa where nis = nis_param limit 1;
  if not found then
    return jsonb_build_object('skor', 0, 'benar', 0, 'totalSoal', 0, 'paket', 'A',
      'waktuSelesai', (extract(epoch from now()) * 1000)::bigint);
  end if;

  v_paket := coalesce(nullif(v_siswa.paket_soal, ''), 'A');
  v_seed := v_siswa.acak_seed;

  if v_paket = 'B' then
    for v_row in select * from soal_paket_b loop
      v_total := v_total + v_row.poin;  v_count := v_count + 1;
      select jawaban into v_jwb from jawaban where nis = nis_param and no_soal = v_row.no;
      if v_jwb is not null then
        if v_seed is null then
          v_orig := upper(v_jwb);
        else
          v_orig := _unshuffle_letter(v_seed, v_row.no, v_jwb);
        end if;
        if v_orig = v_row.kunci then
          v_earned := v_earned + v_row.poin;
        end if;
      end if;
    end loop;
  else
    for v_row in select * from soal_paket_a loop
      v_total := v_total + v_row.poin;  v_count := v_count + 1;
      select jawaban into v_jwb from jawaban where nis = nis_param and no_soal = v_row.no;
      if v_jwb is not null then
        if v_seed is null then
          v_orig := upper(v_jwb);
        else
          v_orig := _unshuffle_letter(v_seed, v_row.no, v_jwb);
        end if;
        if v_orig = v_row.kunci then
          v_earned := v_earned + v_row.poin;
        end if;
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

-- 3h. get_config_guru: config lengkap (dashboard guru). ADMIN_PIN hanya keluar
--     jika pin_param benar (SECURITY DEFINER + _cek_pin).
create or replace function get_config_guru(pin_param text)
returns jsonb language sql security definer as $$
  select case
    when _cek_pin(pin_param) then coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    else jsonb_build_object('error', 'unauthorized')
  end from config;
$$;

-- 3i. simpan_config_guru: upsert pasangan key/value (wajib PIN guru)
create or replace function simpan_config_guru(data jsonb, pin_param text)
returns jsonb language plpgsql security definer as $$
declare k text; v text;
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  for k, v in select * from jsonb_each_text(data) loop
    insert into config (key, value) values (k, v)
      on conflict (key) do update set value = excluded.value;
  end loop;
  return jsonb_build_object('ok', true);
end;
$$;

-- 3j. get_soal_guru: soal LENGKAP dengan kunci (khusus dashboard guru)
create or replace function get_soal_guru(paket_param text, pin_param text)
returns jsonb language sql security definer as $$
  select case
    when _cek_pin(pin_param) then coalesce(jsonb_agg(jsonb_build_object(
      'No', no, 'Pertanyaan', pertanyaan,
      'A', a, 'B', b, 'C', c, 'D', d, 'E', e,
      'Kunci', kunci, 'Poin', poin
    ) order by no), '[]'::jsonb)
    else jsonb_build_object('error', 'unauthorized')
  end
  from (select * from soal_paket_a where paket_param <> 'B'
        union all
        select * from soal_paket_b where paket_param = 'B') t;
$$;

-- 3k. simpan_soal_guru: update (idx>=0) atau insert soal baru (wajib PIN guru)
create or replace function simpan_soal_guru(
  paket_param text, idx_param int default -1,
  pertanyaan_param text default '', a_param text default '', b_param text default '',
  c_param text default '', d_param text default '', e_param text default '',
  kunci_param text default '', poin_param int default 10,
  pin_param text default ''
)
returns jsonb language plpgsql security definer as $$
declare v_id uuid; v_no int;
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
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

-- 3l. hapus_soal_guru: hapus soal berdasarkan urutan tampil (idx) (wajib PIN guru)
create or replace function hapus_soal_guru(paket_param text, idx_param int, pin_param text default '')
returns jsonb language plpgsql security definer as $$
declare v_id uuid;
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
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

-- 3m. toggle_ulangan_guru: YA <-> TIDAK (wajib PIN guru)
create or replace function toggle_ulangan_guru(pin_param text)
returns jsonb language plpgsql security definer as $$
declare v text;
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
  select value into v from config where key = 'ULANGAN_AKTIF';
  v := case when v = 'YA' then 'TIDAK' else 'YA' end;
  insert into config (key, value) values ('ULANGAN_AKTIF', v)
    on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true, 'value', v);
end;
$$;

-- 3n. generate_token_siswa: token baru untuk satu siswa (wajib PIN guru)
create or replace function generate_token_siswa(nis_param text, pin_param text default '')
returns jsonb language plpgsql security definer as $$
declare v_token text := ''; v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
  for i in 1..6 loop
    v_token := v_token || substr(v_chars, floor(random() * length(v_chars))::int + 1, 1);
  end loop;
  update siswa set token_aktif = v_token where nis = nis_param;
  insert into log_aktivitas (nis, event, detail) values (nis_param, 'Generate_Ulang_Token', 'Token: ' || v_token);
  return jsonb_build_object('ok', true, 'token', v_token);
end;
$$;

-- 3o. reset_all_data: kosongkan + seed ulang (dashboard guru, wajib PIN guru)
create or replace function reset_all_data(pin_param text)
returns jsonb language plpgsql security definer as $$
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
  delete from jawaban where true;
  delete from log_aktivitas where true;
  delete from siswa where true;
  delete from soal_paket_a where true;
  delete from soal_paket_b where true;

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

-- 3p. simpan_siswa_guru: tambah/edit siswa (wajib PIN guru). Jika NIS berubah,
--     jawaban & log ikut di-update (tidak orphan).
create or replace function simpan_siswa_guru(
  nis_param text, nama_param text, kelas_param text,
  edit_nis_param text default '', pin_param text default ''
) returns jsonb language plpgsql security definer as $$
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
  if edit_nis_param <> '' then
    if nis_param <> edit_nis_param and exists (select 1 from siswa where nis = nis_param) then
      return jsonb_build_object('ok', false, 'reason', 'NIS sudah ada.');
    end if;
    update siswa set nis = nis_param, nama = nama_param, kelas = kelas_param where nis = edit_nis_param;
    update jawaban set nis = nis_param where nis = edit_nis_param;
    update log_aktivitas set nis = nis_param where nis = edit_nis_param;
    return jsonb_build_object('ok', true);
  end if;
  if exists (select 1 from siswa where nis = nis_param) then
    return jsonb_build_object('ok', false, 'reason', 'NIS sudah ada.');
  end if;
  insert into siswa (nis, nama, kelas, status) values (nis_param, nama_param, kelas_param, 'Belum Mulai');
  return jsonb_build_object('ok', true);
end;
$$;

-- 3q. hapus_siswa_guru: hapus siswa + jawaban + log (wajib PIN guru)
create or replace function hapus_siswa_guru(nis_param text, pin_param text default '')
returns jsonb language plpgsql security definer as $$
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
  delete from jawaban where nis = nis_param;
  delete from log_aktivitas where nis = nis_param;
  delete from siswa where nis = nis_param;
  return jsonb_build_object('ok', true);
end;
$$;

-- 3r. assign_paket_if_empty: tetapkan paket A/B untuk siswa (dipanggil saat login).
--     Idempoten — jika sudah punya paket, tidak diubah.
create or replace function assign_paket_if_empty(nis_param text)
returns jsonb language plpgsql security definer as $$
declare v_siswa siswa%rowtype;
begin
  select * into v_siswa from siswa where nis = nis_param limit 1;
  if not found then return jsonb_build_object('paket', ''); end if;
  if v_siswa.paket_soal is null or v_siswa.paket_soal = '' then
    v_siswa.paket_soal := case when random() < 0.5 then 'A' else 'B' end;
    update siswa set paket_soal = v_siswa.paket_soal, acak_seed = floor(random() * 1000000)::int
      where id = v_siswa.id;
    insert into log_aktivitas (nis, event, detail) values (nis_param, 'Login', 'Paket ' || v_siswa.paket_soal || ' ditetapkan');
  end if;
  return jsonb_build_object('paket', v_siswa.paket_soal);
end;
$$;

-- 3s. ubah_status_siswa: guru mengubah status siswa (wajib PIN guru)
--     Hanya untuk reset (Belum Mulai) atau set selesai manual.
--     Reset juga menghapus waktu_mulai, waktu_selesai, skor.
create or replace function ubah_status_siswa(nis_param text, status_param text, pin_param text default '')
returns jsonb language plpgsql security definer as $$
begin
  if not _cek_pin(pin_param) then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;
  if status_param not in ('Belum Mulai','Selesai') then
    return jsonb_build_object('ok', false, 'reason', 'Status harus Belum Mulai atau Selesai.');
  end if;
  if not exists (select 1 from siswa where nis = nis_param) then
    return jsonb_build_object('ok', false, 'reason', 'Siswa tidak ditemukan.');
  end if;
  if status_param = 'Belum Mulai' then
    update siswa set status = 'Belum Mulai', waktu_mulai = null, waktu_selesai = null, skor = null, acak_seed = null
      where nis = nis_param;
  else
    update siswa set status = 'Selesai', waktu_selesai = now()
      where nis = nis_param;
  end if;
  insert into log_aktivitas (nis, event, detail) values (nis_param, 'Ubah_Status', 'Status -> ' || status_param);
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
-- NOTE: default ADMIN_PIN & TOKEN_MASTER sengaja diacak.
-- Setelah deploy PERTAMA, langsung ubah lewat guru.html -> Config.
-- Untuk DB yang sudah pernah di-seed dengan nilai lama (bocor di history),
-- jalankan UPDATE di bawah dengan nilai baru pilihanmu.

insert into config (key, value) values
  ('JUDUL_ULANGAN', 'Ulangan Harian Matematika & IPA'),
  ('DURASI_MENIT',  '30'),
  ('TOKEN_MASTER',  'QK7XW3Z9'),
  ('ULANGAN_AKTIF', 'YA'),
  ('ADMIN_PIN',     '9B4R2M')
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
