# Aplikasi Ulangan Harian Online — GitHub Pages + Supabase

Rewrite dari versi Google Apps Script ke **static site (GitHub Pages) + Supabase (PostgreSQL)**.

Tidak ada backend server sendiri — semua data & logika dijalankan via Supabase (DB + RLS + RPC + Storage).

## Struktur

```
├── index.html      ← halaman siswa (login NIS+token, soal, timer, tab-switch lock)
├── guru.html       ← dashboard guru (PIN, kelola siswa/soal/config, log)
├── config.js       ← isi URL + anon key Supabase di sini
├── supabase.sql    ← script setup database (tables + RLS + RPC + seed)
└── stitch/         ← dokumentasi desain asli
```

## Setup (1x)

### 1. Buat project Supabase (gratis)
1. Buka https://supabase.com → Sign in → **New project**
2. Beri nama, pilih region terdekat, set password database, **Create**
3. Tunggu sampai selesai provisioning (~1-2 menit)

### 2. Jalankan SQL setup
1. Di dashboard Supabase, buka **SQL Editor** → **New query**
2. Paste isi **seluruh** `supabase.sql`
3. Klik **Run** (boleh dijalankan ulang — idempotent)
4. Hasil: 6 tabel + RLS + 15 RPC + storage bucket `gambar-soal` + seed data

### 3. Ambil kredensial & isi config.js
1. Supabase Dashboard → **Project Settings → API**
2. Salin **Project URL** dan **anon public key**
3. Buka `config.js`, ganti:

```js
const SUPABASE_URL = "https://xxxxxxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIs...";
```

> anon key aman di-publish karena RLS mengunci akses. jangan pernah pakai **service_role key** di frontend.

### 4. Tes lokal
Jalankan server statis di folder ini (tanpa perlu install apa pun, salah satu):

```bash
# Node
npx serve .
# atau Python
python -m http.server 8000
```

Buka `http://localhost:8000/index.html` (siswa) dan `http://localhost:8000/guru.html` (guru).

**Data login demo:**
- Guru: `guru.html` → PIN `1234`
- Siswa: NIS `001234` / `001235` / `001236` → token master `ULANGAN2026`

### 5. Deploy ke GitHub Pages
1. Buat repo baru di GitHub (mis. `ulangan-app`)
2. Push seluruh isi folder ini ke repo:

```bash
git init
git add .
git commit -m "Aplikasi ulangan GH Pages + Supabase"
git branch -M main
git remote add origin https://github.com/<username>/ulangan-app.git
git push -u origin main
```

3. GitHub → repo → **Settings → Pages**
4. **Build and deployment → Source**: pilih `Deploy from a branch` → branch `main`, folder `/ (root)` → **Save**
5. Tunggu 1-2 menit, akses di:
   - Siswa: `https://<username>.github.io/ulangan-app/`
   - Guru: `https://<username>.github.io/ulangan-app/guru.html`

> Update berikutnya cukup `git add . && git commit && git push` — Pages auto re-deploy.

## Alur penggunaan

**Siswa**
1. Buka halaman siswa, input NIS → otomatis muncul nama/kelas & paket soal
2. Masukkan token master (atau token individu) → mulai ulangan
3. Pilih jawaban (auto-save per soal). Timer countdown dari config
4. Pindah tab/window → ulangan terkunci → minta token baru ke guru → unlock & lanjut
5. Waktu habis / klik selesai → skor otomatis dihitung server-side

**Guru**
1. Buka `guru.html`, input PIN (`1234` default, ubah via Config)
2. Dashboard: pantau status siswa real-time
3. Kelola Siswa / Soal (paket A & B, upload gambar) / Config / Log Aktivitas
4. Generate token baru untuk siswa yang terkunci (klik ikon kunci)

## Migrasi data dari Google Sheets lama

Data lama (siswa, soal, jawaban, log) bisa dipindah manual:

1. Buka Supabase → **Table Editor**
2. Buka tabel tujuan (`siswa`, `soal_paket_a`, ...)
3. **Insert row** (per baris) atau ekspor Sheets ke CSV lalu **Import data from CSV**
4. Kolom Sheets → kolom tabel:
   - `Siswa` → `siswa` (NIS, Nama, Kelas, Paket_Soal, Status, Token_Aktif, ...)
   - `Soal_PaketA/B` → `soal_paket_a/b` (No, Pertanyaan, A-E, Kunci, Poin)
   - `Config` → `config` (key/value)

## Keamanan

- **Kunci jawaban** tidak pernah dikirim ke browser — siswa ambil soal via RPC `get_soal_siswa` yang strip kolom kunci; skor dihitung server-side di `submit_ulangan_siswa`
- **ADMIN_PIN** & **TOKEN_MASTER** tersimpan di tabel `config` yang diblokir dari akses langsung — cek PIN lewat RPC `cek_pin_admin`
- RLS: `siswa`, `jawaban`, `log_aktivitas` terbuka (model auth NIS+token, sama seperti versi GAS). Batasi dari luar sekolah bila perlu di tingkat network/jaringan
- Anti-cheat tab-switch bersifat best-effort (batasan browser), tetap perlu pengawasan guru di kelas
