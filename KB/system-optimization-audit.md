# System Optimization Audit — Deep Scan & Reverse Engineering

**Data audit**: 2025-07-15  
**Sistema**: Dell Inspiron 7577  
**OS**: Windows 10 Pro 24H2 Build 26100.8246  
**BIOS**: Dell 1.17.0 (18/03/2022)

---

## 1. Inventario Hardware Completo

### CPU
| Parametro | Valore |
|-----------|--------|
| Modello | Intel Core i7-7700HQ (Kaby Lake, 7th Gen) |
| Core/Thread | 4C / 8T |
| Frequenza base | 2.80 GHz (turbo fino a 3.80 GHz) |
| Cache L3 | 6 MB |
| TDP | 45W |
| Ark Intel | [i7-7700HQ](https://ark.intel.com/content/www/us/en/ark/products/97185/intel-core-i7-7700hq-processor-6m-cache-up-to-3-80-ghz.html) |

### RAM
| Parametro | Valore |
|-----------|--------|
| Capacità totale | 16 GB |
| Tipo | DDR4-2400 (PC4-19200) |
| Slot utilizzati | **1 di 2 (solo DIMM A)** |
| Modulo | Micron 16ATF2G64HZ-2G3B1 |
| Configurazione canale | **SINGLE-CHANNEL** |

### GPU
| GPU | Driver | VRAM | Data driver |
|-----|--------|------|-------------|
| NVIDIA GeForce GTX 1060 Max-Q | 30.0.15.1169 | 6 GB (solo 4 GB visibili a WMI) | 02/01/2022 |
| Intel HD Graphics 630 | 27.20.100.9664 | 1 GB shared | 06/01/2021 |

### Storage Controller
| Parametro | Valore |
|-----------|--------|
| Controller | Intel Chipset SATA/PCIe RST Premium Controller |
| Driver | iaStorAC v17.9.6.1019 |
| Data driver | 02/02/2021 |
| PCI ID | `VEN_8086&DEV_282A&SUBSYS_08021028&REV_31` |
| Modalità | **RAID (Intel RST)** — non AHCI nativo |

### Dischi
| Parametro | NVMe SSD (Disk 1) | HDD (Disk 0) |
|-----------|-------------------|---------------|
| Modello | Toshiba KXG50ZNV256G | Seagate ST1000LM035-1RK172 |
| Capacità | 256 GB (238.5 GB raw) | 1 TB (931.5 GB raw) |
| Interfaccia | NVMe PCIe 3.0 x4 | SATA 6Gb/s |
| RPM | N/A (SSD) | 5400 RPM |
| Firmware | AADA4107 | SDM3 |
| BusType WMI | RAID | RAID |
| **HealthStatus** | **⚠ WARNING — Predictive Failure** | Healthy |
| Lettera | C: (OS) | D: (Storage) |
| NTFS Cluster | 4096 bytes | 4096 bytes |

### Partizioni NVMe (Disk 1)
| # | Dimensione | Tipo | Note |
|---|-----------|------|------|
| 1 | 100 MB | EFI System | |
| 2 | 100 MB | MSR (Reserved) | |
| 3 | 222.1 GB | C: (Basic) | OS |
| 4 | 1.3 GB | Recovery | ⚠ |
| 5 | 13.3 GB | Recovery | ⚠ |
| 6 | 1.1 GB | Recovery | ⚠ |

> **3 partizioni di recovery = ~15.7 GB** su un drive da 238.5 GB quasi pieno.

### Rete
| Adapter | Driver | Link Speed | Stato |
|---------|--------|-----------|-------|
| Intel Dual Band Wireless-AC 8265 | 20.70.25.2 | 400 Mbps | Up |
| Realtek PCIe GbE Family Controller | 1.0.0.14 | — | Disconnected |
| Tailscale Tunnel | 0.14.0.0 | 100 Gbps (virtual) | Up |
| VMware VMnet1/8 | 14.0.0.7 | 100 Mbps (virtual) | Up |

---

## 2. FINDING CRITICI — Priorità Immediata

### 🔴 CRITICO-1: NVMe Predictive Failure
- **Get-PhysicalDisk** riporta `HealthStatus=Warning`, `OperationalStatus=Predictive Failure`
- Driver Intel RST blocca l'accesso diretto ai contatori SMART (StorageReliabilityCounter restituisce dati vuoti)
- **Firmware corrente**: AADA4107
- **Toshiba KXG50ZNV256G**: SSD enterprise-class NVMe, prodotto da Kioxia (ex-Toshiba Memory)
- **Azione raccomandata**: 
  1. **BACKUP IMMEDIATO** di tutti i dati su C:
  2. Installare CrystalDiskInfo o smartmontools per lettura SMART diretta (bypassando RST)
  3. Verificare firmware più recente su [Kioxia Support](https://business.kioxia.com/en-us/ssd.html)
  4. Se i contatori SMART confermano usura (Percentage Used > 90%, Media/Data Integrity Error), **pianificare sostituzione disco**

### 🔴 CRITICO-2: Spazio Disco Criticamente Basso
| Volume | Libero | Totale | % Libero | Stato |
|--------|--------|--------|----------|-------|
| C: (NVMe) | **7.1 GB** | 222.1 GB | **3.2%** | ⛔ CRITICO |
| D: (HDD) | **3.3 GB** | 931.5 GB | **0.35%** | ⛔ CRITICO |

**Impatto prestazionale**:
- NVMe: write amplification drammaticamente aumentata con <10% free; il controller SSD non può fare garbage collection e wear leveling efficienti
- HDD: la testina deve cercare blocchi liberi frammentati; impossibile deframmentare
- Windows non può gestire file temporanei, Windows Update fallisce, pagefile non può espandersi
- **Raccomandazione minima**: almeno 15-20% libero su entrambi i drive

**Occupazione C: (222.1 GB totali, ~215 GB usati)**:
| Cartella | Dimensione | Recuperabile? |
|----------|-----------|---------------|
| Users | 60.7 GB | Parziale (pulizia profile, cache) |
| Program Files | 33.5 GB | Review installazioni |
| Program Files (x86) | 23.6 GB | Review installazioni |
| ProgramData | 21.4 GB | Parziale (cache, log) |
| pagefile.sys | **20.0 GB** | **Sì — ridurre** |
| Windows (stima) | ~45 GB | Parziale (WinSxS cleanup) |
| hiberfil.sys | **6.3 GB** | **Sì — disabilitare se non usata** |
| Recovery partitions | **15.7 GB** | **Sì — eliminabili** |
| iso_xubuntu | 0.7 GB | Sì |
| TEMP utente | 3.3 GB | **Sì** |
| WinSxS backup/disabled | **9.57 GB** | **Sì (DISM cleanup)** |

**Occupazione D: (931.5 GB totali, ~928 GB usati)**:
| Cartella | Dimensione |
|----------|-----------|
| Condivisa_con_Macchine_Virtuali | 33.9 GB |
| Da DESKTOP | 32.8 GB |
| Incoming | 21.2 GB |
| Lavori Pasquale | 3.1 GB |
| Lavori TEKNA | 2.1 GB |
| _local_backups_apricenadialetto | 1.9 GB |
| thermo_connection | 1.7 GB |
| sr5000 keyence | 1.5 GB |
| CryptoPredictions | 1.3 GB |
| AdobeAcrobat | 1.1 GB |
| downloads | 1.0 GB |

### 🔴 CRITICO-3: RAM Single-Channel
- **Solo DIMM A popolato** con un modulo da 16 GB
- Il sistema opera in **single-channel** invece di dual-channel
- **Penalità bandwidth**: ~40% (~19.2 GB/s single vs ~34.1 GB/s dual per DDR4-2400)
- Impatto su: tutto ciò che è I/O intensive su RAM — VM, compilazioni, editing video, database
- **Soluzione**: aggiungere un secondo modulo DDR4-2400 da 16 GB in DIMM B (o sostituire con 2×8 GB dual-channel se 32 GB non servono)
- **Compatibilità**: Micron 16ATF2G64HZ-2G3B1 o equivalente (DDR4-2400 SODIMM 260-pin)

---

## 3. FINDING IMPORTANTI — Prestazioni Disco

### 🟠 IMP-1: Intel RST RAID Mode vs AHCI Nativo
- Entrambi i dischi appaiono come `BusType=RAID` e `InterfaceType=SCSI`
- Il driver **iaStorAC v17.9.6.1019** (2021) è datato; versione corrente Intel RST: **~19.5.x** (2024)
- **Problemi Intel RST**:
  - Aggiunge un layer di astrazione tra OS e disco
  - **Blocca SMART nativo** (contatori StorageReliabilityCounter vuoti)
  - Può interferire con TRIM scheduling nativo di Windows
  - Overhead latenza su operazioni NVMe
- **Opzioni**:
  1. **Aggiornare driver RST** a v19.5.x (rischio basso, miglioramento moderato)
  2. **Passare a AHCI** nel BIOS se non ci sono volumi RAID reali (richiede procedura specifica per evitare BSOD):
     - Impostare `HKLM\SYSTEM\CurrentControlSet\Services\iaStorV\Start` = 0
     - Impostare `HKLM\SYSTEM\CurrentControlSet\Services\storahci\Start` = 0
     - Riavviare in Safe Mode
     - Cambiare BIOS da RAID a AHCI
     - Riavviare normalmente
  3. **Beneficio AHCI**: latenza NVMe più bassa, SMART nativo, TRIM nativo, compatibilità driver Microsoft standard

### 🟠 IMP-2: Pagefile da 20 GB Fisso su C:
- Pagefile impostato a **dimensione fissa 20480 MB** (20 GB) su C:
- AutomaticManagedPagefile = **False**
- Con 16 GB di RAM, il pagefile raccomandato è **8-16 GB** (non 20 GB)
- Su un disco con solo 7 GB liberi, il pagefile occupa il **9% del volume**
- **Azione**:
  1. Ridurre a **8192 MB fisso** (metà della RAM) — libera **~12 GB** su C:
  2. In alternativa: spostare su D: (ma D: è anche pieno) oppure rendere automatico con Initial=4096 Max=16384
  3. Dopo aver liberato spazio su D:, considerare di spostare pagefile su D:

### 🟠 IMP-3: Hibernation Attiva (6.3 GB)
- `hiberfil.sys` occupa **6.3 GB** su C:
- Il sistema ha solo Standby S3 disponibile (non ibernazione completa)
- **Azione**: `powercfg /hibernate off` — libera immediatamente **6.3 GB**
- Se si usa Fast Startup: `powercfg /hibernate /size 0` riduce hiberfil ma mantiene Fast Startup

### 🟠 IMP-4: Recovery Partitions (15.7 GB)
- 3 partizioni di recovery sull'NVMe occupano **15.7 GB**
- Se esiste un backup recovery esterno o un'immagine di sistema, sono eliminabili
- **Azione** (con cautela): eliminare tramite diskpart dopo aver creato USB recovery
- **Spazio recuperabile**: ~15.7 GB

### 🟠 IMP-5: WinSxS Component Store Cleanup
- DISM riporta: "Backup e funzionalità disabilitate: 9.57 GB" — **Pulizia consigliata: Sì**
- **Azione**: `Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase`
- **Spazio recuperabile stimato**: ~5-9 GB

---

## 4. FINDING MODERATI — Ottimizzazioni Software

### 🟡 MOD-1: Visual Effects = "Let Windows Decide" (Valore 3)
- Attualmente il sistema decide autonomamente gli effetti visivi
- Su un laptop con NVMe quasi pieno e GPU discreta, le animazioni consumano risorse
- **Azione**: Impostare su "Adjust for best performance" (valore 2) dove non necessario
- `SystemPropertiesPerformance.exe` → selezionare "Regola per prestazioni ottimali"

### 🟡 MOD-2: Servizi Non Necessari in Esecuzione
Servizi che potrebbero essere disabilitati se non utilizzati:
| Servizio | DisplayName | Note |
|----------|-------------|------|
| Autocad2010 | Autocad2010 | Se AutoCAD 2010 non è in uso attivo |
| CODESYS Gateway V3 | CODESYS Gateway V3 | Avviare solo quando serve |
| CODESYS ServiceControl | CODESYS ServiceControl | Avviare solo quando serve |
| SharedAccess | Condivisione connessione Internet (ICS) | Se non si condivide connessione |
| Spooler | Spooler di stampa | Se non si stampa da questo PC |
| FlexNet Licensing Service 64 | FlexNet Licensing | Se non serve sempre |
| MySQL80 | MySQL80 | Avviare solo quando serve |
| AnyDesk | AnyDesk Service | Avviare solo quando serve |
| W3SVC + IISADMIN + WAS | IIS Web Server | Se non serve un web server locale |
| SRManagementToolFtpServer | SR FTP Server | Se non serve |
| AdobeARMservice | Adobe Update | Schedulare invece di tenere always-on |
| CODESYSControlSysTray | CODESYS SysTray | Startup entry non necessario |
| GatewaySysTray | CODESYS Gateway SysTray | Startup entry non necessario |
| SmartConnect | Lenovo SmartConnect | Valutare se necessario |

### 🟡 MOD-3: Startup Programs
| Entry | Path | Azione suggerita |
|-------|------|-----------------|
| CODESYSControlSysTray | Program Files\CODESYS...\CODESYSControlSysTray.exe | Rimuovere da Run, avviare manualmente |
| GatewaySysTray | Program Files\CODESYS...\GatewaySysTray.exe | Rimuovere da Run |
| SmartConnect | Program Files\Lenovo\Ready For Assistant\SmartConnect.exe | Disabilitare se non usato |
| Chrome AutoLaunch | chrome.exe --no-startup-window /prefetch:5 | Valutare rimozione |

### 🟡 MOD-4: NTFS Memory Usage Default
- `MemoryUsage = 0` (default) — il kernel NTFS usa la quantità standard di pool per metadata caching
- Con 16 GB di RAM, si può incrementare a 2 per allocare più pool alla cache NTFS
- `fsutil behavior set memoryusage 2` — migliora le performance di accesso a molti file piccoli
- **Rischio**: basso, reversibile con `fsutil behavior set memoryusage 0`

### 🟡 MOD-5: MFT Zone Piccola
- `MftZone = 0` (200 MB) — zona MFT minima
- Con volumi molto pieni, la MFT si frammenta e degrada le performance
- **Azione** (dopo aver liberato spazio): `fsutil behavior set mftzone 2` (600 MB)

### 🟡 MOD-6: SystemResponsiveness = 20
- Default Windows (20% risorse riservate a processi background)
- Per uso desktop/workstation, ridurre a **10** o **0** (tutto al foreground)
- **Azione**: Impostare `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\SystemResponsiveness` = 10
- **Rischio**: basso, reversibile

### 🟡 MOD-7: Network TCP — Scaling Heuristics Disabled
- `ScalingHeuristics = Disabled` — OK, non interferisce con auto-tuning
- `AutoTuningLevelLocal = Normal` — OK
- `CongestionProvider = CUBIC` — OK, protocol moderno
- Offload settings: RSS, RSC, TaskOffload tutti attivi — OK
- **Nessuna azione necessaria**

---

## 5. STATO CONFIGURAZIONE — Già Ottimizzato ✅

| Setting | Valore | Stato |
|---------|--------|-------|
| Power Plan | Prestazioni elevate (High Performance) | ✅ Ottimo |
| SysMain (Superfetch) | Disabled / Stopped | ✅ Ottimo |
| Windows Search (WSearch) | Disabled / Stopped | ✅ Ottimo |
| Prefetcher | Disabled (0) | ✅ Ottimo |
| TRIM (DisableDeleteNotify) | 0 (TRIM attivo) | ✅ Ottimo |
| Last Access Timestamp | Disabled (1) | ✅ Ottimo |
| 8.3 Filename Creation | Disabled (1) | ✅ Ottimo |
| Defrag Scheduled Task | Ready | ✅ OK |
| TCP Auto-Tuning | Normal | ✅ OK |
| RSS / RSC / TaskOffload | Enabled | ✅ OK |

---

## 6. Piano di Intervento Prioritizzato

### Fase 1 — Emergenza Spazio (stima recupero: ~35-45 GB su C:)

| # | Azione | Spazio | Rischio | Reversibilità |
|---|--------|--------|---------|---------------|
| 1.1 | `powercfg /hibernate off` | **+6.3 GB** | Basso | `powercfg /hibernate on` |
| 1.2 | Ridurre pagefile da 20 GB a 8 GB | **+12 GB** | Basso | Riaumentare se OOM |
| 1.3 | `Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase` | **+5-9 GB** | Basso | Non reversibile (rimuove backup aggiornamenti) |
| 1.4 | Pulizia TEMP utente (3.3 GB) | **+3 GB** | Basso | Nessun impatto |
| 1.5 | Rimuovere `C:\iso_xubuntu` se non serve | **+0.7 GB** | Basso | Re-download |
| 1.6 | Disk Cleanup avanzato (`cleanmgr /sageset:1`) | **+1-5 GB** | Basso | N/A |
| 1.7 | Eliminare recovery partitions (solo dopo USB recovery) | **+15.7 GB** | **Medio** | Non reversibile |

### Fase 2 — Spazio D: (richiede review utente)

| # | Azione | Note |
|---|--------|------|
| 2.1 | Review `Da DESKTOP` (32.8 GB) | Possibile archivio esterno? |
| 2.2 | Review `Condivisa_con_Macchine_Virtuali` (33.9 GB) | VM attive? Comprimibili? |
| 2.3 | Review `Incoming` (21.2 GB) | File temporanei scaricati? |
| 2.4 | Review `downloads` (1 GB) | Pulire file già estratti |

### Fase 3 — Prestazioni Disco (dopo aver liberato spazio)

| # | Azione | Impatto | Rischio |
|---|--------|---------|---------|
| 3.1 | Aggiornare driver Intel RST a v19.5.x | Medio | Basso |
| 3.2 | Valutare passaggio RAID → AHCI nel BIOS | **Alto** | **Medio** (seguire procedura) |
| 3.3 | `fsutil behavior set memoryusage 2` | Basso-Medio | Basso |
| 3.4 | `fsutil behavior set mftzone 2` | Basso | Basso |
| 3.5 | SystemResponsiveness → 10 | Basso | Basso |
| 3.6 | Deframmentare D: dopo aver liberato spazio | Medio su HDD | Basso |

### Fase 4 — Hardware (budget permettendo)

| # | Azione | Impatto | Costo stimato |
|---|--------|---------|---------------|
| 4.1 | **Aggiungere DIMM B** (16 GB DDR4-2400 SODIMM) | **+40% bandwidth RAM** | ~25-40€ |
| 4.2 | **Sostituire NVMe** (Predictive Failure!) | **Critico per affidabilità** | ~35-60€ (500GB NVMe) |
| 4.3 | Sostituire HDD con SSD 2.5" 1TB | **Enorme** su D: | ~60-80€ |

### Fase 5 — Servizi e Startup

| # | Azione |
|---|--------|
| 5.1 | Impostare CODESYS/MySQL/IIS/AnyDesk a `StartType=Manual` |
| 5.2 | Rimuovere CODESYSControlSysTray e GatewaySysTray da HKLM\...\Run |
| 5.3 | Valutare disabilitazione SmartConnect e Chrome AutoLaunch |
| 5.4 | Visual Effects → "Adjust for best performance" |

---

## 7. Riferimenti Hardware Ufficiali

### Toshiba/Kioxia KXG50ZNV256G
- **Famiglia**: XG5 Series (client NVMe SSD)
- **Interfaccia**: PCIe 3.0 x4, NVMe 1.2.1
- **Velocità sequenziale**: Read 3000 MB/s, Write 790 MB/s (256 GB model)
- **Endurance**: 128 TBW (256 GB model)
- **Firmware noto**: AADA4107 — verificare se Kioxia ha rilasciato aggiornamenti
- **Datasheet**: [Kioxia XG5 Series](https://business.kioxia.com/en-us/ssd/client-ssd/xg5.html)
- **Nota**: 128 TBW potrebbe essere stato raggiunto se il drive ha scritto pesantemente per anni con spazio basso (write amplification elevata)

### Seagate ST1000LM035-1RK172
- **Famiglia**: Barracuda Mobile (2.5", 7mm)
- **Capacità**: 1 TB
- **RPM**: 5400
- **Cache**: 128 MB
- **Interfaccia**: SATA 6 Gb/s
- **Firmware**: SDM3
- **Datasheet**: [Seagate Barracuda Mobile](https://www.seagate.com/products/hard-drives/barracuda-hard-drive/)
- **Performance note**: 5400 RPM limita la velocità sequenziale a ~120-140 MB/s e l'IOPS random è molto basso (~80 IOPS); è il collo di bottiglia principale per D:

### Intel RST Premium Controller (DEV_282A)
- **PCI ID**: 8086:282A
- **Driver attuale**: iaStorAC 17.9.6.1019 (Feb 2021)
- **Driver più recente**: Intel RST 19.5.x / iaStorAC 19.x (2024)
- **Download**: [Intel RST Drivers](https://www.intel.com/content/www/us/en/download/720755/intel-rapid-storage-technology-driver-installation-software-with-intel-optane-memory.html)
- **Nota**: L'aggiornamento del driver RST va fatto con attenzione; creare un punto di ripristino prima

### Dell Inspiron 7577 BIOS
- **Versione corrente**: 1.17.0 (Mar 2022)
- **Supporto**: [Dell Inspiron 7577 Drivers](https://www.dell.com/support/home/en-us/product-support/product/inspiron-15-7577-laptop/drivers)
- **Nota**: Verificare se disponibili versioni BIOS più recenti per miglioramenti termici e compatibilità

### Intel Wireless-AC 8265
- **Driver corrente**: 20.70.25.2
- **Driver più recente**: ~22.x.x (dal sito Intel)
- **Download**: [Intel Wi-Fi Drivers](https://www.intel.com/content/www/us/en/download/18231/intel-proset-wireless-software-and-drivers-for-windows-10-and-windows-11.html)

---

## 8. Script di Intervento Rapido

### Script Fase 1 — Recupero Spazio C: (eseguire come Administrator)

```powershell
# === FASE 1: Recupero spazio rapido C: ===
# Stima recupero: ~25-30 GB (escluse recovery partitions)

# 1.1 Disabilitare ibernazione (-6.3 GB)
Write-Host "[1.1] Disabilitando ibernazione..." -ForegroundColor Cyan
powercfg /hibernate off
Write-Host "  hiberfil.sys rimosso: +6.3 GB liberati" -ForegroundColor Green

# 1.2 Ridurre pagefile a 8 GB (-12 GB)
Write-Host "[1.2] Riducendo pagefile a 8 GB..." -ForegroundColor Cyan
$cs = Get-CimInstance Win32_ComputerSystem
$cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$false}
$pf = Get-CimInstance Win32_PageFileSetting -Filter "Name='c:\\pagefile.sys'"
if ($pf) {
    $pf | Set-CimInstance -Property @{InitialSize=8192; MaximumSize=8192}
} else {
    New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name="c:\pagefile.sys"; InitialSize=8192; MaximumSize=8192}
}
Write-Host "  Pagefile ridotto a 8 GB (effettivo al riavvio): +12 GB" -ForegroundColor Green

# 1.3 DISM Component Cleanup
Write-Host "[1.3] Pulizia WinSxS..." -ForegroundColor Cyan
Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase

# 1.4 Pulizia TEMP
Write-Host "[1.4] Pulizia TEMP utente..." -ForegroundColor Cyan
$tempPath = [System.IO.Path]::GetTempPath()
$before = (Get-ChildItem $tempPath -Recurse -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
Get-ChildItem $tempPath -Recurse -Force -EA SilentlyContinue | 
    Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
    Remove-Item -Force -EA SilentlyContinue
$after = (Get-ChildItem $tempPath -Recurse -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host "  TEMP: liberati $('{0:N0} MB' -f (($before - $after)/1MB))" -ForegroundColor Green

# 1.5 Pulizia Windows Temp
Write-Host "[1.5] Pulizia Windows\Temp..." -ForegroundColor Cyan
Get-ChildItem 'C:\Windows\Temp' -Recurse -Force -EA SilentlyContinue |
    Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -EA SilentlyContinue

# Riepilogo
Write-Host "`n=== RIEPILOGO ===" -ForegroundColor Yellow
$free = (Get-Volume -DriveLetter C).SizeRemaining
Write-Host "Spazio libero C: $('{0:N1} GB' -f ($free/1GB))" -ForegroundColor White
Write-Host "NOTA: pagefile si riduce solo dopo riavvio!" -ForegroundColor Yellow
```

### Comandi singoli per ottimizzazioni NTFS

```powershell
# MFT Zone (dopo aver liberato spazio)
fsutil behavior set mftzone 2

# NTFS Memory Usage (con 16+ GB RAM)
fsutil behavior set memoryusage 2

# System Responsiveness (più risorse al foreground)
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -Value 10
```

### Comandi per servizi non necessari

```powershell
# Impostare servizi a Manual (avvio solo quando necessario)
@('MySQL80','AnyDesk','CODESYS Gateway V3','CODESYS ServiceControl',
  'W3SVC','IISADMIN','WAS','AppHostSvc','FlexNet Licensing Service 64',
  'SRManagementToolFtpServer','SRManagementToolFileMonitorService',
  'Autocad2010','AdobeARMservice','SharedAccess') | ForEach-Object {
    $svc = Get-Service -Name $_ -EA SilentlyContinue
    if ($svc -and $svc.StartType -ne 'Manual') {
        Set-Service -Name $_ -StartupType Manual -EA SilentlyContinue
        Write-Host "  $_ → Manual" -ForegroundColor Green
    }
}
```

---

## 9. Metriche Pre/Post da Monitorare

| Metrica | Comando | Pre-optimization |
|---------|---------|:----------------:|
| Spazio C: | `(Get-Volume C).SizeRemaining / 1GB` | **7.1 GB** |
| Spazio D: | `(Get-Volume D).SizeRemaining / 1GB` | **3.3 GB** |
| NVMe Health | `(Get-PhysicalDisk)[1].HealthStatus` | **Warning** |
| Servizi running | `(Get-Service \| ? Status -eq Running).Count` | ~100+ |
| Boot time | Event Log: `EventID=100, Microsoft-Windows-Diagnostics-Performance` | Da misurare |
| RAM bandwidth | `winsat mem` | Single-channel |

---

## 10. Note Finali

1. **L'NVMe in Predictive Failure è il rischio più alto**: qualsiasi ottimizzazione è inutile se il disco si rompe. Priorità assoluta = backup + diagnostica SMART.
2. **Lo spazio disco è il bottleneck #1 per le prestazioni**: con 3% e 0.35% libero, Windows non può operare efficientemente. La Fase 1 può liberare 25-30 GB su C: in pochi minuti.
3. **Il single-channel RAM è il bottleneck hardware più facile da risolvere**: un modulo DDR4-2400 SODIMM da 16 GB costa 25-40€ e dà un boost del 40% sulla bandwidth.
4. **Intel RST vs AHCI** è la decisione più impattante sul lungo termine per le prestazioni NVMe, ma richiede preparazione.
5. **L'HDD a 5400 RPM** su D: sarà sempre lento per accesso random — la sostituzione con un SSD 2.5" SATA è l'unico miglioramento reale per D:.

---

## 11. Verifica Deterministica Post-Reboot (2026-04-17)

### Best next decision
Confermare chiusa la fase di ottimizzazione software safe e passare alla fase hardware/capacita: liberazione spazio su D:, upgrade RAM dual-channel e piano sostituzione NVMe in predictive failure.

### Metriche pre/post (misurate)

| Metrica | Pre | Post reboot | Delta |
|---------|-----|-------------|-------|
| Spazio libero C: | 7.1 GB (3.2%) | **23.55 GB (10.61%)** | **+16.45 GB** |
| Spazio libero D: | 3.3 GB (0.35%) | 3.29 GB (0.35%) | ~0 |
| Pagefile C: | 20480/20480 MB | **8192/8192 MB** | **-12 GB occupati** |
| Ibernazione | Attiva | **Disattivata** | hiberfil rimosso |
| Servizi non essenziali | Auto/Running | **Manual + Stopped (13/13)** | overhead boot ridotto |
| SystemResponsiveness | 20 | **10** | foreground piu reattivo |
| NTFS memoryusage | 0 | **2** | cache metadata aumentata |
| NTFS mftzone | 0 | **2 (400 MB)** | frammentazione MFT ridotta |
| Visual effects | 3 (Windows decide) | **2 (best performance)** | carico UI ridotto |
| CrystalDiskInfo | Assente | **Installato (9.8.0)** | monitor SMART attivo |
| Finding audit totali | 10 | **6** | **-40%** |
| Finding critici | 4 | **2** | **-50%** |

### Finding residui (post-reboot)
- `DISK-SPACE-D`
- `RAM-CHANNEL-001`
- `DISK-SPACE-C`
- `DRIVER-RST-001`
- `DRIVER-RST-002`
- `STARTUP-001`

### Check anti-regressione
- Nessun servizio e stato terminato forzatamente dopo reboot: i 13 servizi target risultano `StartMode=Manual` e `State=Stopped`.
- Modifiche pagefile/NTFS applicate come previsto e persistenti dopo reboot.
- Nessuna modifica aggressiva applicata (no switch AHCI, no rimozione recovery partition, no stop processi utente aperti).

### Evidenze generate
- `logs/health-audit-postreboot.json`
- `logs/post-reboot-verification.json`
- `scripts/post-reboot-verify.ps1`
