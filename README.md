# hermes-termux-kit

Satu perintah untuk memasang **Hermes Agent** — **JALUR 1: Termux/Android**
(asal kit ini) dan **JALUR 2: Windows via WSL2** (beta) — lahir dari rebuild
nyata (bukan teori), jadi tidak ada yang perlu mengulang berjam-jam.

```bash
# JALUR 1 — Termux/Android
pkg install -y git
git clone https://github.com/Lheyonk-code/hermes-termux-kit
cd hermes-termux-kit
bash install.sh

# JALUR 2 — Windows via WSL2 (Ubuntu/Debian; sekali saja dari PowerShell: wsl --install -d Ubuntu)
git clone https://github.com/Lheyonk-code/hermes-termux-kit
cd hermes-termux-kit
bash install.sh
```

**Urutannya sekarang: provider + API key dulu, baru install.** Saat pertama
dijalankan, `install.sh` membuka **wizard interaktif** (Langkah 0) untuk mengisi
provider dan key — minimal 1 provider, boleh tambah beberapa (dipakai untuk
auto-rotate). Setelah kredensial siap, install berjalan sekali jalan sampai
health check + smoke test.

## Dua jalur: JALUR 1 (Termux) & JALUR 2 (Windows WSL2 — beta)

Satu `install.sh` untuk dua platform. **Deteksi platform jalan di paling
awal, satu fungsi (`detect_platform`)** — dan platform yang tidak dikenal
(mis. macOS) **berhenti dengan pesan jelas**:

| Deteksi | Platform | Jalur |
| --- | --- | --- |
| `$TERMUX_VERSION` terisi, atau `$PREFIX` mengandung `com.termux/files/usr` | Termux/Android | JALUR 1 (perilaku asli, tidak berubah) |
| `/proc/version` mengandung `Microsoft`/`WSL`, atau `$WSL_DISTRO_NAME` terisi, atau `uname -r` mengandung `microsoft` | Windows via WSL2 | JALUR 2 (beta) |
| Linux biasa (bukan keduanya) | Linux | JALUR 2 varian Linux — perilaku lama non-Termux, tanpa bagian khusus WSL |
| lainnya | tidak dikenal | berhenti dengan pesan jelas |

**STATUS JALUR 2: beta — belum teruji end-to-end di mesin Windows asli.**
Yang dikerjakan sejauh ini hanya `bash -n` + dry-run di Linux. Jangan anggap
jalur ini matang.

**Yang SAMA di dua jalur** (logika dipakai ulang, bukan dikopi): Langkah 0
wizard provider + API key (key hanya di `~/.hermes/.env`, chmod 600),
pilihan gateway injector/9Router (saling eksklusif), ai-memory opsional
(default tidak), health check + smoke test.

**Yang BERBEDA — hanya blok mesinnya:**

- **Install Hermes**: WSL2/Linux memakai **installer resmi untuk Linux/WSL**
  dari `hermes-agent.nousresearch.com` — bukan repo APT canary Termux.
- **Service**: bila systemd di WSL aktif (`[boot] systemd=true` di
  `/etc/wsl.conf`; dicek via `/run/systemd/system` + `systemctl
  is-system-running`), dipasang unit systemd bernama `hermes-kit-<nama>.service`
  (`hermes-kit-hermes-serve` + `hermes-kit-injector`/`hermes-kit-9router`
  (+ `hermes-kit-ai-memory` kalau dipilih)) — `enable --now`, saling
  eksklusif seperti di Termux. Kalau systemd **TIDAK** aktif: WSL tanpa
  systemd tidak punya autostart — dibuat **script start manual**
  `~/.hermes/start-hermes-wsl.sh` (idempoten, jalankan tiap awal sesi /
  tambahkan ke `~/.bashrc` / Task Scheduler Windows), plus arahan
  mengaktifkan systemd lalu menjalankan ulang `install.sh`.
- **Pengganti langkah cek-APK**: arahan memasang **Hermes Desktop Companion**
  di sisi **Windows** — dari WSL tidak bisa memasang aplikasi Windows secara
  diam-diam, jadi cukup link resmi + langkah singkat, lalu bisa dilewati
  (pilihan tersimpan di `~/.hermes/desktop-check.mode`, idempoten).
  Desktop bersifat **opsional** — tanpa itu Hermes di WSL tetap jalan penuh
  dari terminal. Link:

  - Unduhan: https://hermes-agent.nousresearch.com/desktop
  - Microsoft Store: https://apps.microsoft.com/detail/9pmxk8czc7kr
  - Dokumentasi: https://hermes-agent.nousresearch.com/docs/user-guide/desktop

Batasan JALUR 2 (jujur): belum teruji end-to-end di Windows asli; WSL tanpa
systemd = tidak ada autostart (hanya start manual); `health_check.py` membaca
status service gaya runsv — status layanan systemd tidak muncul di output-nya
(cek provider + HTTP tetap jalan). Aturan yang sama di kedua jalur: **tanpa
Tor, tanpa Bariska; key hanya di `~/.hermes/.env` (chmod 600).**

## Langkah 0 — provider + API key dulu

Sebelum menyentuh prerequisites/binary, `install.sh` mengecek
`~/.hermes/providers.yaml` + `~/.hermes/.env`:

- **Belum ada key provider yang terisi** → wizard interaktif berjalan:
  per provider ditanya **nama, base_url, default_model (boleh kosong), dan
  API key**. Key ditulis **HANYA** ke `~/.hermes/.env` (chmod 600, input
  disembunyikan); `providers.yaml` memakai referensi `"${NAMA_ENV}"` — nol
  key plaintext di file config. Setelah provider pertama, ditawari tambah
  provider lagi (2, 3, ... sesuai jumlah yang diisi — chain untuk auto-rotate).
- **Sudah terisi** → Langkah 0 dilewati. **Idempoten**: install ulang /
  `git pull` + `bash install.sh` lagi **tidak pernah menimpa** kredensial yang
  sudah ada (nilai lama di `.env` dipertahankan; `providers.yaml` lama
  dicadangkan ke `.bak.<tanggal>` sebelum ditulis ulang).

## Cek APK Hermes (aplikasi mobile) — setelah Langkah 0

Setelah wizard provider selesai (sebelum setup service), install mengecek
apakah **APK mobile Hermes Agent** sudah terpasang di HP:

- **Sudah terpasang** → `APK Hermes terdeteksi (<nama paket>)` dan langkah
  ini **dilewati** — install lanjut seperti biasa. **Idempoten**: install
  ulang pada HP yang sudah punya APK tidak menampilkan arahan lagi.
- **Belum terpasang** → install berhenti sejenak: tautan unduhan
  APK ditampilkan, dibuka di browser HP via `termux-open-url` (fallback
  `termux-open`), diberi instruksi singkat, lalu install **menunggu user
  menekan Enter** setelah selesai memasang. Ada pilihan **`s` = lewati**
  dengan peringatan (tanpa APK mobile, Hermes hanya bisa dipakai dari
  terminal Termux). Pilihan lewati tersimpan di `~/.hermes/apk-check.mode`
  supaya install berikutnya tidak mengarahkan lagi (hapus file itu kalau
  berubah pikiran).
- **Aman-gagal**: kalau mekanisme deteksi paket tidak tersedia/diblokir ROM
  (`pm`/`cmd package` gagal dijalankan), install **tidak digagalkan** —
  cukup peringatan + arahkan APK, diperlakukan seperti jalur "belum
  terdeteksi".

Deteksi memakai `pm list packages` (fallback `cmd package list packages`) —
tanpa root. Di host Linux non-Termux langkah ini dilewati (tidak relevan).

Link unduhan APK (sekali klik):

- Unduhan: https://github.com/omarqaterge/hermes-mobile-app/releases/latest
- Repo: https://github.com/omarqaterge/hermes-mobile-app

> **Catatan kejujuran:** tidak ada APK Android resmi dari Nous Research
> (jalur resminya desktop/Termux). Aplikasi default yang diarahkan kit
> ini adalah **Hermes Mobile (omarqaterge)** — aplikasi komunitas
> open-source (MIT) yang didistribusikan lewat repo GitHub-nya, bukan
> buatan Nous. Ganti tautannya kapan saja lewat `HERMES_APK_URL` di bawah.
Tautan unduhan bisa dioverride tanpa mengedit repo:

```bash
HERMES_APK_URL="https://github.com/omarqaterge/hermes-mobile-app/releases/latest" bash install.sh
```

## Pilih gateway — injector bawaan (default) atau 9Router (opsional)

Setelah Langkah 0, install bertanya **satu kali**: gateway mana yang jalan.
**Saling eksklusif — hanya SATU gateway yang dipasang & dijalankan:**

- **1) injector bawaan kit** (default, Enter tanpa memilih). Ringan, tanpa
  dependency tambahan: `tools/injector.py` di `:20129`. Perilaku lama lengkap.
- **2) 9Router (opsional)**. `npm install -g 9router` + service runsv sendiri
  (buat service injector **tidak dibuat**; yang lama dimatikan — `sv down` +
  di-rename ke `.injector.disabled`, tidak dihapus). 9Router hidup sebagai
  **satu-satunya gateway**: dashboard `http://127.0.0.1:20128`, endpoint
  OpenAI-compatible `http://127.0.0.1:20128/v1`, butuh Node.js
  (di-install otomatis kalau belum ada).

**Idempoten & bisa diganti kapan pun:**

```bash
bash install.sh --gateway=9router    # ganti ke 9Router (injector dimatikan)
bash install.sh --gateway=injector   # kembali ke injector (9Router dimatikan)
bash install.sh                      # tanpa flag: pakai pilihan yang tersimpan,
                                     # atau tanya sekali (Enter = injector)
```

Pilihan tersimpan di `~/.hermes/gateway.mode` (install ulang tidak menanya
lagi). Koneksi provider chain dari wizard ke 9Router dilakukan **sebisa
mungkin**: `providers.yaml` (base_url/model) + key di `~/.hermes/.env`
ditampilkan siap tempel, lalu provider dimasukkan di dashboard 9Router sebagai
provider custom OpenAI-compatible — 9Router mengelola token/OAuth provider di
dashboard-nya sendiri, dan bagian itu tidak bisa di-scripting dari luar.

Key provider tetap **hanya** di `~/.hermes/.env` (chmod 600), di dua mode.
Tanpa Tor, tanpa Bariska — jalur langsung.

`health_check.py` ikut pilihan ini: yang dicek **hanya gateway aktif**
(injector → service `injector`; 9router → service `9router` + HTTP :20128).
Gateway yang tidak terpilih tidak muncul dan tidak pernah dihitung merah.

## ai-memory (opsional) — memori persisten Hermes

Setelah pemilihan gateway, install bertanya sekali: **"Pasang ai-memory?" —
DEFAULT TIDAK.** Tanpa jawaban `y`, **tidak ada apa pun yang dipasang.**

Kalau dijawab ya, yang dipasang (pola terbukti di Termux):

- **Server** `ai-memory` v3.1.1 ([akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory)),
  binary resmi upstream, **sha256 diverifikasi sebelum unpack**, terpasang di
  dalam **proot-debian** (`proot-distro install debian` — di-install otomatis
  kalau belum ada).
- **Bind loopback saja**: `127.0.0.1:49374` — tidak keluar dari HP.
- **Service autostart** runsv bernama `ai-memory` — ikut menyala saat terminal/HP
  menyala, berdampingan dengan `hermes-serve` + gateway terpilih.
- **Config Hermes** diarahkan ke `memory.provider: ai-memory`
  (+ pointer `~/.hermes/ai-memory.json` → `http://127.0.0.1:49374`).
- **Konsolidasi LLM memakai provider chain MILIKMU sendiri** dari Langkah 0
  (provider pertama di `providers.yaml`): base_url + model ditulis ke
  `~/.hermes/aimemory.env`, key dirujuk sebagai `${NAMA_VAR}` dan diekspor saat
  service start dari `~/.hermes/.env`. **Nol key plaintext di file lain, nol
  gateway pihak ketiga.** Kalau chain belum terbaca, server jalan zero-LLM dulu
  (FTS5 search tetap hidup) — jalankan ulang `install.sh` setelah wizard provider.

**Idempoten & data aman:** data memori hidup di `~/.local/share/ai-memory`
(di-mount ke proot saat service jalan). Install ulang, `--aimemory` berulang,
atau `git pull` **tidak pernah menyentuh** datanya; binary yang sudah ada
tidak diunduh ulang. Pilihan tersimpan di `~/.hermes/aimemory.mode` (yes/no)
supaya install berikutnya tidak menanya lagi.

**Catatan resource (jujur):** proot-debian sendiri butuh **~1GB storage** plus
RAM ekstra saat server berjalan. **Tidak disarankan untuk HP RAM ≤ 3GB.** Kalau
HP bata tipis, lewati — tanpa ai-memory Hermes tetap utuh.

Ganti pilihan kapan pun:

```bash
bash install.sh --aimemory      # pasang (ikuti wizard kalau baru pertama)
bash install.sh --no-aimemory   # catat "tidak" (service lama tidak dihapus otomatis)
```

`health_check.py` juga ikut: ai-memory hanya dicek kalau dipasang
(service + HTTP `:49374`). Kalau tidak dipilih, dia tampil **netral** —
"tidak dipilih (komponen opsional — dilewati, bukan gagal)" — tidak pernah
merah dan tidak mengubah exit code.

## Yang dikerjakan `install.sh`

0. **Langkah 0 — provider + API key** — wizard interaktif kalau belum terisi
   (lihat di atas); dilewati kalau sudah
0b. **Cek APK Hermes** — deteksi aplikasi mobile Hermes Agent di HP
   (Termux only): sudah terpasang = dilewati; belum = arahkan link unduhan +
   buka di browser + tunggu Enter (opsi `s` = lewati dengan peringatan,
   tersimpan di `~/.hermes/apk-check.mode`). Aman-gagal: ROM yang memblokir
   deteksi tetap lanjut install (lihat di atas). **JALUR 2 (WSL2): langkah
   ini diganti arahan pasang Hermes Desktop Companion di sisi Windows**
   (lihat section "Dua jalur" di atas)
1. **Deteksi platform** — satu fungsi di paling awal: Termux → JALUR 1,
   WSL2/Linux → JALUR 2, lainnya → berhenti dengan pesan jelas. Lalu
   **prerequisites** — git, curl, gnupg (+ python3 di Linux/WSL2, auto
   `pkg install` / `apt-get install` kalau kurang)
2. **Binary Hermes** — Termux: repo APT resmi Nous Research, **fingerprint
   PGP diverifikasi dulu** (salah fingerprint = berhenti, bukan lanjut
   diam-diam). Probe otomatis channel `stable` → `canary` (`stable` sering
   404). Di Linux non-Termux / WSL2, jatuh ke installer resmi Linux/WSL.
3. **Config + `.env`** — `~/.hermes` dibuat mode 700, `.env` mode 600
4. **Provider chain** — `providers.yaml` + **semua key dipindah ke `.env`**
   (nol plaintext tersebar di repo/file config)
5. **Pilihan gateway** — wizard sekali: injector bawaan (default) atau
   9Router (opsional); tersimpan di `~/.hermes/gateway.mode`, bisa diganti
   lewat `--gateway=...` (lihat di atas). Saling eksklusif.
6. **Service autostart** — `hermes-serve` + **gateway terpilih saja**:
   `injector` (`:20129`, default) atau `9router` (dashboard `:20128`),
   `hermes-maintain` (+ `ai-memory` **hanya kalau dipilih** — lihat di atas).
   Termux: runsv (termux-services). **WSL2: unit systemd `hermes-kit-*` bila
   systemd aktif, selain itu script start manual `~/.hermes/start-hermes-wsl.sh`**
7. **Auto-rotate + cek sehat berkala** — cron `every 6h` + service runsv
8. **Health check + smoke test** — provider benar-benar diuji `--chat`, lalu `hermes -z`

Tanpa Tor, tanpa proxy — jalur langsung.

## Auto-rotate & cek sehat

`health_check.py` tidak berhenti di "koneksi hidup". Dia:
- resolusi key dari `~/.hermes/.env`
- `GET /models` → endpoint hidup + key diterima
- `POST /chat/completions` (`--chat`) → benar-benar bisa dipakai
- cek mode `.env`, config, status service runsv
- `--smoke` → uji `hermes -z` end-to-end
- `--json` → keluaran mesin (untuk cron/monitoring), `exit 0` = sehat

`rotate_keys.py` dua tugas terpisah:
- `--env-only` — tarik key literal nyasar ke `~/.hermes/.env` (idempoten, tanpa jaringan)
- `--rotate` — rotasi di provider **hanya kalau endpoint rotasinya benar-benar
  diketahui**. Kalau tidak ada, script **tidak mengarang key** — dia bilang
  "rotate manual di dashboard". Kejujuran > terlihat otomatis.
- `--scrub` — bersihkan key lama dari file/DB (`state.db`) setelah rotasi

`hermes-maintain.sh` menggabungkan keduanya + ringkasan ke `~/logs/hermes-maintain.log`.
**Watchdog:** stdout kosong = sehat (tidak mengirim apa pun); ada alarm = masalah.

## `injector.py` — satu pintu ke provider chain

`hermes serve` menangani chat Hermes sendiri. `tools/injector.py` dipakai kalau
kamu butuh **proxy OpenAI-compatible di `:20129`** yang bisa dipakai klien lain —
atau mau menguji provider chain tanpa mengganggu sesi Hermes:

```bash
python3 tools/injector.py serve                 # service di http://127.0.0.1:20129/v1
python3 tools/injector.py chat -m "halo"         # satu prompt lewat chain
python3 tools/injector.py providers              # daftar chain + prioritas
python3 tools/injector.py env-check              # cek resolusi ${VAR} dari ~/.hermes/.env
python3 tools/injector.py health                 # GET /models tiap provider (exit 1 kalau mati semua)
```

Tiga hal yang dia tangani:
- **Key dari `${VAR}`** — literal di `providers.yaml` juga jalan; `${VAR}` diambil
  dari env proses lalu `~/.hermes/.env`.
- **Jatuh ke cadangan** — provider ber-`fallback: true` dipakai kalau yang di
  atasnya gagal, dan `model` diganti ke model milik provider tujuan (bukan
  model provider utama yang kebetulan ikut di-request).
- **Bisa dimonitor** — `GET /health` melaporkan upstream aktif, status tiap
  provider, dan chain-nya (nol dependency, aman untuk cron).

Klien OpenAI mana pun tinggal diarahkan ke `http://127.0.0.1:20129/v1`.
Header `X-Injector-Echo: 1` menyisipkan blok `_injector` (upstream + latensi +
percobaan ke-berapa) di balasan — berguna saat membuktikan failover benar terjadi.

## Jalan juga tanpa `termux-services`

Auto-rotate + cek sehat punya **dua jalur**: service runsv (tahan restart HP) dan
cron Hermes (`hermes cron create "every 6h" --name hermes-maintain --script
hermes-maintain.sh --no-agent`). Salah satu tidak tersedia, yang lain jalan.

> Cron menolak symlink & path di luar `~/.hermes/scripts/` — `install.sh` menaruh
> **salinan nyata** di sana, bukan link.

## Opsi

```
bash install.sh --no-services     # tanpa runsv service
bash install.sh --no-injector     # tanpa injector
bash install.sh --gateway=9router # pakai 9Router sebagai satu-satunya gateway
bash install.sh --gateway=injector# kembali ke injector (default)
bash install.sh --aimemory        # pasang ai-memory (opsional; default TIDAK)
bash install.sh --no-aimemory     # catat "tidak" untuk ai-memory
bash install.sh --canary|--stable # paksa channel APT
bash install.sh --dry-run         # tunjukkan langkahnya saja
bash update.sh                    # tarik pembaruan repo (config hidup tidak tersentuh)
```

## Update aman

`git pull` di repo ini **tidak pernah menyentuh** `~/.hermes` (config, `.env`,
memories, sessions) — semuanya di luar repo. `update.sh` juga mengulang health
check setelah pull.

## Kredensial

Semua key hidup di `~/.hermes/.env` (chmod 600) dan dirujuk sebagai `${NAMA_VAR}`
di `providers.yaml`. `providers.yaml` di repo ini **nol key literal** — verifikasi
otomatis di akhir `rotate_keys.py --env-only`. `tools/injector.py env-check`
memeriksa hal yang sama tanpa jaringan: dia bilang provider mana yang `${VAR}`-nya
tidak ketemu, sebelum kamu bingung kenapa request gagal.

## Catatan jujur (bukan klaim berlebihan)

- **JALUR 2 (WSL2) adalah beta — belum pernah diuji end-to-end di mesin
  Windows asli.** Yang dikerjakan hanya `bash -n`, dry-run lintas platform
  (`HERMES_PLATFORM=termux|wsl2|linux|unknown`), dan uji format unit systemd
  di Linux. Perilaku install di WSL nyata (path, systemd WSL, installer
  resmi di dalam WSL) belum diverifikasi langsung. Laporan bug diterima.
- **`install.sh` sekarang ber-shebang `#!/usr/bin/env bash`** (sebelumnya
  path bash Termux) supaya satu file jalan juga di WSL/Linux. Di Termux
  tetap dipanggil lewat `bash install.sh` (cara pemakaian di README tidak
  berubah).
- **Verifikasi PGP** hanya jalan di Termux (repo APT upstream menolak Termux;
  installer resmi dipakai di Linux/WSL2).
- **`--rotate`** bergantung provider. Kebanyakan provider tidak punya endpoint rotasi publik
  → jalur manual di dashboard. Ini kondisi provider, bukan bug kit.
- **Cron butuh gateway hidup** untuk menyala sendiri. Tanpa gateway, job tetap
  tersimpan dan bisa dipicu manual (`hermes cron run <job_id>`).
- **`health_check.py` dikenal-samar**: provider berstatus `blocked` /
  `blocked_ip_403` dihitung sebagai *kondisi diketahui* (IP mobile diblok), bukan
  kegagalan baru — supaya exit code tidak merah terus tiap 6 jam.
- **ai-memory** jalan zero-LLM sampai provider chain terisi (konsolidasi LLM
  menunggu chain dari wizard; FTS search tidak menunggu). Server hanya bind
  `127.0.0.1` — tidak pernah terekspos keluar HP. Butuh proot-debian (~1GB
  storage + RAM) — lewati di HP RAM ≤ 3GB.
- **9Router**: koneksi provider lewat dashboard miliknya (token/OAuth per
  provider) — bagian itu tidak bisa di-scripting dari luar, jadi kit
  menyiapkan data chain siap tempel, bukan menyuntik config. Token provider
  yang 9Router simpan sendiri ada di storage 9Router, di luar kendali kit;
  key chain kit tetap hanya di `~/.hermes/.env`. 9Router juga lebih berat
  dari injector (Node.js + dashboard) — makanya injector tetap default.

## Lisensi

MIT.
