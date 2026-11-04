from pathlib import Path
import subprocess, tempfile, importlib.util, csv
root=Path(__file__).resolve().parent
src=root.parent/'03_FIR_C'
out=root/'fir_snr';out.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory() as td:
    exe=Path(td)/'fir_host.exe'
    subprocess.run(['gcc','-std=c99','-O2','-Wall','-Wextra','-Werror','-DFIR_HOST','-DFIR_DUMP=1',*[str(src/n) for n in ['fir_bench.c','fir_kernels.c','fir_model_check.c']],'-o',str(exe)],check=True)
    result=subprocess.run([str(exe)],capture_output=True,text=True,check=True)
spec=importlib.util.spec_from_file_location('verify',src/'verify_host.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
v.verify(result.stdout,32,1024,10)
(out/'host_dump.txt').write_text(result.stdout,encoding='utf-8')
with (out/'fir_outputs.csv').open('w',newline='') as f:
    w=csv.writer(f);w.writerow(['input','width','frame','sample','source_q15','accumulator'])
    for line in result.stdout.splitlines():
        if line.startswith('DATA,'):w.writerow(line.split(',')[1:])
print('PASS: 61440 C outputs verified and exported; timing is obtained separately in ASIP CA.')
