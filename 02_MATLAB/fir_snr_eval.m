% Numerical evaluation aligned with fir_mulp optimized_v1, Release CA experiment.
% Data: host execution of unchanged C kernels with FIR_HOST and FIR_DUMP=1.
% Reference and SNR formula follow fir_multiplier_demo.m.
root = fullfile(fileparts(mfilename('fullpath')),'fir_snr');
d = readtable(fullfile(root,'fir_outputs.csv'),'TextType','string');
L=32; fc=0.1; k=0:L-1;
z=2*fc*(k-(L-1)/2);
s=ones(size(z)); nz=z~=0; s(nz)=sin(pi*z(nz))./(pi*z(nz));
h=2*fc*s.*(0.54-0.46*cos(2*pi*k/(L-1))); h=h/sum(h);
inputs=["random","two_tone"]; widths=[8,16,32]; fx=[3,7,15]; fh=[6,10,15];
rows=cell(6,5); ri=0;
for input=inputs
 for mi=1:3
  rowsel=d.input==input & d.width==widths(mi);
  t=d(rowsel,:); assert(height(t)==10240);
  assert(isequal(t.frame*1024+t.sample,(0:10239)'));
  x=double(t.source_q15)/2^15;
  yref=filter(h,1,x);
  y=double(t.accumulator)/2^(fx(mi)+fh(mi));
  % Independently check arithmetic-truncated coefficients and integer FIR.
  b=floor(h*2^31); frac=h*2^31-b;
  q31=b+double(frac>0.5 | (frac==0.5 & mod(b,2)~=0));
  qh=floor(q31/2^(31-fh(mi)));
  qx=floor(double(t.source_q15)/2^(15-fx(mi)));
  assert(isequal(filter(qh,1,qx),double(t.accumulator)));
  snr=10*log10(sum(yref.^2)/sum((yref-y).^2));
  ri=ri+1; rows(ri,:)={char(input),widths(mi),snr,0,10239};
  fprintf('%s W%d SNR = %.9f dB\n',input,widths(mi),snr);
 end
end
results=cell2table(rows,'VariableNames',{'input','width','snr_db','first_sample','last_sample'});
writetable(results,fullfile(root,'snr_results.csv'));
save(fullfile(root,'snr_results.mat'),'results','h');
fprintf('PASS: 6 modes checked against C outputs. All 10240 samples included, continuous history, zero initial state.\n');
