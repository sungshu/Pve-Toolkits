from pathlib import Path
import re
from datetime import date

p = Path('src/pve/disk_monitor.sh')
s = p.read_text(encoding='utf-8')

s = s.replace('VERSION="1.0.52"', 'VERSION="1.0.53"', 1)
s = s.replace('UPDATED="2026-09-01"', 'UPDATED="2026-09-11"', 1)
s = s.replace('disk_monitor_1.0.52_cpu', 'disk_monitor_1.0.53_cpu')
s = s.replace('disk_monitor_1.0.52_disk', 'disk_monitor_1.0.53_disk')
s = s.replace('disk_monitor_1.0.52_subscription', 'disk_monitor_1.0.53_subscription')
s = s.replace('disk_monitor_1.0.52', 'disk_monitor_1.0.53')

cpu = r'''cat > "$CONTENT_CPU_JS" <<'JS'
// disk_monitor_1.0.53_cpu

{
    itemId: 'dm_cpumhz',
    colspan: 2,
    printBar: false,
    title: gettext('CPU 運作狀態'),
    textField: 'cpuFreq',
    renderer: function(v){
        if (!v) return '無法取得 CPU 資訊';

        let m = v.match(/cpu MHz\s*:\s*[\d.]+/ig) || [];
        let f = [];

        m.forEach(function(x){
            let z = x.match(/[\d.]+$/);
            if (z) f.push(Number(z[0]) / 1000);
        });

        let text = '';

        if (f.length) {
            let avg = f.reduce(function(a,b){ return a + b; }, 0) / f.length;
            text = '平均: ' + avg.toFixed(2) + ' GHz (' +
                Math.min.apply(null, f).toFixed(1) + ' ~ ' +
                Math.max.apply(null, f).toFixed(1) + ' GHz)';
        }

        let g = v.match(/(?<=^gov:).+/im);
        let govName = (g && g[0].trim() !== '') ? g[0].trim().toUpperCase() : 'NONE';
        text += ' | 調速器模式: ' + govName;

        return text;
    }
},

{
    itemId: 'dm_thermalstate',
    colspan: 2,
    printBar: false,
    title: gettext('CPU溫度 (°C)'),
    textField: 'thermalstate',
    renderer: function(value){
        if (!value || value === 'No sensor data') return '無感測器資料';

        function colorizeCpuTemp(temp) {
            const tempNum = parseFloat(temp);
            if (Number.isNaN(tempNum)) return temp + '°C';
            if (tempNum < 60) return '<span style="color: #27ae60; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
            if (tempNum < 80) return '<span style="color: #f39c12; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
            return '<span style="color: #e74c3c; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
        }

        let cpuResults = [];
        let otherList = [];
        let nicCount = 0;
        let blocks = value.trim().split(/\n\s*\n/);

        blocks.forEach(function(block){
            let lines = block.split('\n');
            let chip = (lines[0] || '').trim();

            if (/nvme/i.test(chip)) return;

            if (/coretemp|k10temp|zenpower|zenpower3|k8temp|fam15h|zenprobe/i.test(chip)) {
                let temps = [];
                let tempRegex = /(?:Package id \d+|Tctl|Tdie|Core \d+|Tccd\d+):\s*\+?(-?\d+(?:\.\d+)?)\s*°C/ig;
                let tMatch;
                while ((tMatch = tempRegex.exec(block)) !== null) {
                    temps.push(Number(tMatch[1]));
                }

                if (temps.length > 0) {
                    let packageTemp = temps[0];
                    let coreTemps = temps.slice(1);
                    let detail = '封裝: ' + colorizeCpuTemp(packageTemp);

                    if (coreTemps.length > 0) {
                        let avgCore = coreTemps.reduce(function(a,b){ return a + b; }, 0) / coreTemps.length;
                        let maxCore = Math.max.apply(null, coreTemps);
                        let minCore = Math.min.apply(null, coreTemps);
                        detail += ' | 核心: 平均 ' + colorizeCpuTemp(avgCore) +
                            ' (' + colorizeCpuTemp(minCore) + '~' + colorizeCpuTemp(maxCore) + ')';
                    }

                    cpuResults.push(detail);
                }
            } else {
                let devName = chip.split('-')[0].toUpperCase();
                let devMatch = block.match(/(?:temp1|Composite|Board|Sensor \d+):\s*([+-]?\d+(?:\.\d+)?)\s*°C/i);

                if (devMatch) {
                    if (/BNXT|TG3|E1000|IXGBE|I40E|ICE|MLX/i.test(devName)) {
                        nicCount++;
                        devName = '網卡' + nicCount;
                    }
                    otherList.push(devName + ': ' + colorizeCpuTemp(Number(devMatch[1])));
                }
            }
        });

        let linesOut = [];

        if (cpuResults.length > 0) {
            cpuResults.forEach(function(temp, idx){
                let line = 'CPU' + idx + ': ' + temp;
                if (otherList[idx]) line += ' | ' + otherList[idx];
                linesOut.push(line);
            });

            for (let j = cpuResults.length; j < otherList.length; j++) {
                linesOut.push(otherList[j]);
            }
        } else {
            let matches = value.match(/[+-]?\d+(?:\.\d+)?\s*°C/g);
            if (matches && matches.length) {
                linesOut.push('感測器: ' + matches.map(function(x){ return colorizeCpuTemp(parseFloat(x)); }).join(' | '));
            } else {
                linesOut.push('正常');
            }
        }

        return linesOut.join('<br>');
    }
},
JS
'''
pat = r'cat > "\$CONTENT_CPU_JS" <<\x27JS\x27\n.*?^JS\n'
s2, n = re.subn(pat, cpu, s, count=1, flags=re.M|re.S)
if n != 1:
    raise SystemExit('CPU block not found')
s = s2

# Add PVE Tools-style storage temperature helpers.
needle = "cat > \"$CONTENT_DISK_JS\" <<'JS'\n// disk_monitor_1.0.53_disk\nJS"
replacement = '''cat > "$CONTENT_DISK_JS" <<'JS'
// disk_monitor_1.0.53_disk
JS
cat > "$BASE_DIR/temp_helpers.js" <<'JS'
function colorizeNvmeTemp(temp) {
    const tempNum = parseFloat(temp);
    if (Number.isNaN(tempNum)) return temp + '°C';
    if (tempNum < 50) return '<span style="color: #27ae60; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
    if (tempNum < 70) return '<span style="color: #f39c12; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
    return '<span style="color: #e74c3c; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
}

function colorizeDiskTemp(temp) {
    const tempNum = parseFloat(temp);
    if (Number.isNaN(tempNum)) return temp + '°C';
    if (tempNum < 40) return '<span style="color: #27ae60; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
    if (tempNum < 50) return '<span style="color: #f39c12; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
    return '<span style="color: #e74c3c; font-weight: 600;">' + tempNum.toFixed(0) + '°C</span>';
}
JS
'''
if needle not in s:
    raise SystemExit('disk helper anchor not found')
s = s.replace(needle, replacement, 1)

# Put helper functions at the top of the generated disk JS.
s = s.replace('cat >> "$CONTENT_DISK_JS" <<JS\n{\n    itemId:', 'cat "$BASE_DIR/temp_helpers.js" >> "$CONTENT_DISK_JS"\n\ncat >> "$CONTENT_DISK_JS" <<JS\n{\n    itemId:', 1)

# Use the appropriate PVE Tools temperature classifier in each disk renderer.
s = s.replace("s += ' | 溫度: ' + v.temperature.current + '°C';", "s += ' | 溫度: ' + colorizeNvmeTemp(v.temperature.current);", 1)
s = s.replace("s += ' | 溫度: ' + v.temperature.current + '°C';", "s += ' | 溫度: ' + colorizeDiskTemp(v.temperature.current);", 1)
s = s.replace("s += ' | 溫度: ' +\n                    v.temperature.drive_temperature + '°C';", "s += ' | 溫度: ' + colorizeDiskTemp(v.temperature.drive_temperature);", 1)

# The SATA block may have the same one-line temperature expression; replace remaining one.
s = s.replace("s += ' | 溫度: ' + v.temperature.current + '°C';", "s += ' | 溫度: ' + colorizeDiskTemp(v.temperature.current);", 1)

# Include a visible red marker for non-zero NVMe unsafe shutdown count, matching the PVE Tools concept.
old = "s += ' (開關機: ' + v.power_cycle_count + ' 次)';"
new = "s += ' (開關機: ' + v.power_cycle_count + ' 次)';"
# Keep power-cycle semantics unchanged; unsafe-shutdown is not exposed by the current backend JSON.

p.write_text(s, encoding='utf-8')
print('updated', p)
