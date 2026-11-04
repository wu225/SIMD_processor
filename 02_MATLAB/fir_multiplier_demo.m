function results = fir_multiplier_demo(makePlots, roundingMode, srSeed)
% FIR_MULTIPLIER_DEMO  多精度低位乘法器的FIR数值验证示例。
%
% 运行：
%   results = fir_multiplier_demo;                    % 默认SR，并绘图
%   results = fir_multiplier_demo(false);             % 默认SR，不绘图
%   results = fir_multiplier_demo(false,'sr',20261003);% 固定SR随机轨迹
%   results = fir_multiplier_demo(false,'rne');       % 最近偶数舍入对照
%   results = fir_multiplier_demo(false,'trunc');     % 算术右移截断对照
%
% 只使用基础MATLAB函数，不依赖Signal Processing/Fixed-Point Toolbox。
% 本文件包含子函数；请以完整文件运行，不要只复制某一节。
%
% 三个层次：
%   1. 浮点FIR：filter(h,1,x)，作为数值质量参考；
%   2. 定点标量FIR：每个抽头做一次完整整数乘法，32位累加；
%   3. 定点SIMD FIR：pack -> PMUL低W位 -> 符号扩展 -> 32位累加。
%
% 注意：
%   PMUL8/16/32是用户乘法器的数学行为模型，不是RTL结构模型。
%   本文件不模拟流水线、访存对齐指令、CPU cycle、功耗或面积。
%   打印的乘法指令数仅包括乘法，不包括打包、拆包、累加及访存。
%   各模式的小数位数与lane位宽不同，不能称为Q1.7/Q1.15/Q1.31乘法。
%
% 与论文对齐：输入pre-scaling、系数降精度和输出post-scaling的右移
% 默认采用SR。浮点到高精度整数的离线fixture准备使用RNE，不算运行时SR。
% 正负数统一：Q=floor(v/2^r)，D=v-Q*2^r；若U<D则输出Q+1。
% U是[0,2^r-1]的伪随机整数。左右移不改变PMUL低位乘法语义。
% 每个模式独立初始化LCG32，按正序系数->输入->输出顺序消费随机字；
% 系数先离线量化，保持同一seed下的系数表不随帧长N改变。
% 每个右移元素消费一字，包括零和可精确表示的值。左移/不移位不消费。
% 标量/SIMD共用相同整数输入、系数及输出舍入随机轨迹。
% 已在MATLAB R2024b实机验证；数值与随机轨迹可导出供ISS逐位比对。
% 官方文档：
% https://www.mathworks.com/help/matlab/ref/filter.html
% https://www.mathworks.com/help/matlab/ref/bitshift.html
% https://www.mathworks.com/help/matlab/ref/idivide.html

if nargin < 1
    makePlots = true;
end
if nargin < 2
    roundingMode = 'sr';
end
if nargin < 3
    srSeed = 20261003;
end
roundingMode = lower(char(roundingMode));
assert(any(strcmp(roundingMode,{'sr','rne','trunc'})), ...
    'roundingMode must be sr, rne or trunc.');
assert(isnumeric(srSeed) && isreal(srSeed) && isscalar(srSeed) && isfinite(double(srSeed)) && ...
    double(srSeed) >= 0 && double(srSeed) <= 2^32-1 && ...
    double(srSeed) == floor(double(srSeed)), 'srSeed must be a uint32 value.');

%% 1. 可以从这里修改实验参数
N = 1024;                  % 每帧输出个数
L = 32;                    % 抽头数：第一版建议16、32、64
fc = 0.10;                 % 截止频率/fs；范围(0,0.5)
Fsource = 15;              % 所有模式共用的原始输入小数位
FcoefficientSource = 31;   % 离线系数fixture的高精度小数位
Fout = 15;                 % 所有模式共用的输出小数位
inputType = 'two_tone';    % 'two_tone'/'random'/'impulse'/'zero'
modeConfig = [8, 3, 6;     % 每一行：[W, Fx, Fh]
              16, 7, 10;
              32, 15, 15];
assert(N >= 1 && L >= 4 && mod(L,4) == 0);
assert(fc > 0 && fc < 0.5);

% 内置检查：PMUL、RNE、SR概率/负数/PRNG、三种舍入和16/32/64抽头。
tests = run_self_checks;

%% 2. 浮点滤波器系数：窗函数法，直流增益归一化为1
h = design_lowpass(L, fc);
n = 0:N-1;
rng(20261003, 'twister');
switch inputType
    case 'two_tone'
        % 0.03fs在通带，0.30fs在阻带；总幅度不超过0.8。
        xIdeal = 0.6*sin(2*pi*0.03*n) + 0.2*sin(2*pi*0.30*n);
    case 'random'
        xIdeal = 0.8*(2*rand(1,N)-1);
    case 'impulse'
        xIdeal = zeros(1,N);
        xIdeal(1) = 0.75;
    case 'zero'
        xIdeal = zeros(1,N);
    otherwise
        error('Unknown inputType.');
end
assert(all(abs(xIdeal) <= 1), '输入范围须满足abs(x)<=1。');

% 原始输入作为32位字保存的Q15整数码，供各模式共同使用。
% 对应ISS里的source buffer；之后各模式的格式转换由运行时执行。
qSource = int64(round_even_double(xIdeal * 2^Fsource));
xSource = double(qSource) / 2^Fsource;
% 固定高精度系数fixture；之后每个模式的右移降精度使用选定舍入。
qhSource = int64(round_even_double(h * 2^FcoefficientSource));

% 浮点参考使用同一输入的真实值、未量化系数、零初始状态。
yFloat = filter(h, 1, xSource);

results = struct;
results.N = N;
results.L = L;
results.fc_over_fs = fc;
results.inputType = inputType;
results.roundingMode = roundingMode;
results.srSeed = uint32(srSeed);
results.Fsource = Fsource;
results.FcoefficientSource = FcoefficientSource;
results.qhSource = qhSource;
results.srContract = struct('prng','LCG32', ...
    'recurrence','state=(1664525*state+1013904223) mod 2^32', ...
    'modeSeed','(srSeed+W) mod 2^32', ...
    'uniform','top r bits of updated state', ...
    'increment','U < remainder, base=floor(v/2^r)', ...
    'consumption','one word per right-shift element, including exact/zero values', ...
    'order','coefficient tap order, input sample order, output sample order', ...
    'fixtureRounding','RNE for float to input Q15 and coefficient Q31');
results.h = h;
results.xIdeal = xIdeal;
results.qSource = qSource;
results.xSource = xSource;
results.yFloat = yFloat;
results.tests = tests;
results.note = 'Numerical model, MUL-only and SR draw counts; no processor cycles.';

fprintf('\nFIR: L=%d, N=%d, fc/fs=%.2f, input=%s\n',L,N,fc,inputType);
fprintf('All modes use the same source input and a signed 32-bit accumulator.\n');
fprintf('Scaling rounding=%s, SR base seed=%u; offline source fixtures use RNE.\n', ...
    upper(roundingMode),uint32(srSeed));
fprintf(' W   Fx  Fh  BitMatch   SNR(dB)    ScalarMUL    SIMD_MUL_only\n');

%% 3. 分别验证三种精度模式
for mi = 1:size(modeConfig,1)
    W = modeConfig(mi,1);
    Fx = modeConfig(mi,2);
    Fh = modeConfig(mi,3);
    lanes = 32/W;

    % 各模式使用独立、可跨语言重现的随机流；不依赖MATLAB全局rng。
    initialState = uint32(bitand(uint64(srSeed)+uint64(W),uint64(2^32-1)));
    [qh,coefficientTrace] = round_shift_integer(qhSource,FcoefficientSource-Fh, ...
        roundingMode,initialState);
    [qx,inputTrace] = round_shift_integer(qSource,Fsource-Fx, ...
        roundingMode,coefficientTrace.finalState);

    % 保证：每个原始有符号乘积能放进W位；整个FIR能用32位累加。
    [productBound, accumulatorBound] = check_format(qx,qh,W,Fx);

    % 标量参考按原始FIR公式计算；SIMD按递增窗口、反序系数计算。
    accScalar = fir_scalar_integer(qx,qh);
    [accSIMD, packedCoefficients, nPMUL] = fir_simd_integer(qx,qh,W);
    assert(isequal(accScalar,accSIMD), '标量/SIMD原始累加值不一致。');

    % 所有模式统一为“小数15位、用32位字保存”的输出。
    shiftOut = Fx+Fh-Fout;  % 8位模式为-6；16位为2；32位为15
    % 从同一个PRNG状态重放输出舍入，防止把随机差异误判为SIMD错误。
    [qyScalar,outputTrace] = round_shift_integer(accScalar,shiftOut, ...
        roundingMode,inputTrace.finalState);
    [qySIMD,simdOutputTrace] = round_shift_integer(accSIMD,shiftOut, ...
        roundingMode,inputTrace.finalState);
    assert(isequal(outputTrace,simdOutputTrace), '标量/SIMD随机轨迹不一致。');
    assert(isequal(qyScalar,qySIMD), '标量/SIMD输出不一致。');
    assert(all(qySIMD >= int64(-2^31) & qySIMD <= int64(2^31-1)));
    yFixed = double(qySIMD)/2^Fout;
    snrDB = calculate_snr(yFloat,yFixed);

    mode = struct;
    mode.W = W;
    mode.Fx = Fx;
    mode.Fh = Fh;
    mode.Fout = Fout;
    mode.roundingMode = roundingMode;
    mode.lanes = lanes;
    mode.qx = qx;
    mode.qh = qh;
    mode.hQuantized = double(qh)/2^Fh;
    mode.packedCoefficients = packedCoefficients;
    mode.accScalar = accScalar;
    mode.accSIMD = accSIMD;
    mode.qy = qySIMD;
    mode.y = yFixed;
    mode.error = yFixed-yFloat;
    mode.snrDB = snrDB;
    mode.bitExact = isequal(qyScalar,qySIMD);
    mode.productBound = productBound;
    mode.accumulatorBound = accumulatorBound;
    mode.roundingTrace = struct('input',inputTrace, ...
        'coefficient',coefficientTrace,'output',outputTrace);
    mode.runtimeSRDrawCount = inputTrace.drawCount+outputTrace.drawCount;
    mode.offlineCoefficientSRDrawCount = coefficientTrace.drawCount;
    mode.scalarMULCount = N*L;
    mode.SIMD_MULOnlyCount = nPMUL;
    assert(nPMUL == N*L/lanes);
    results.modes(mi) = mode;

    fprintf('%2d   %2d  %2d      %d     %8.2f     %8d       %8d\n', ...
        W,Fx,Fh,mode.bitExact,snrDB,N*L,nPMUL);
    fprintf('     product bound=%d, accumulator bound=%d, output shift=%d\n', ...
        productBound,accumulatorBound,shiftOut);
    fprintf('     runtime SR draws=%d, offline coefficient SR draws=%d\n', ...
        mode.runtimeSRDrawCount,mode.offlineCoefficientSRDrawCount);
end

%% 4. 展示一条PMUL8到底做了什么
toyA = int64([3,-2,4,1]);     % lane0到lane3
toyB = int64([5,2,-3,2]);
A = pack_signed_lanes(toyA,8);
B = pack_signed_lanes(toyB,8);
P = pmul_low(A,B,8);
toyProducts = unpack_signed_lanes(P,8);
assert(isequal(toyProducts,int64([15,-4,-12,2])));
fprintf('\nOne PMUL8 example (lane0 is the least significant byte):\n');
fprintf('A=0x%s, B=0x%s, P=0x%s\n',dec2hex(A,8),dec2hex(B,8),dec2hex(P,8));
fprintf('Signed lane products = [%d %d %d %d], sum=%d\n', ...
    toyProducts(1),toyProducts(2),toyProducts(3),toyProducts(4), ...
    sum_integer(toyProducts));
fprintf('MUL-only counts are NOT CPU cycles or full-program instruction counts.\n');

%% 5. 可视化：全部由本次运行结果生成
if makePlots
    show_plots(results);
end
end

function h = design_lowpass(L,fc)
% h[k]=2fc*sinc(2fc*(k-(L-1)/2))*Hamming[k]，再归一化。
k = 0:L-1;
z = 2*fc*(k-(L-1)/2);
s = ones(size(z));
nz = (z ~= 0);
s(nz) = sin(pi*z(nz))./(pi*z(nz));
window = 0.54-0.46*cos(2*pi*k/(L-1));
h = 2*fc*s.*window;
h = h/sum(h);
end

function q = round_even_double(v)
% 最近偶数舍入；避免把MATLAB默认round当成最近偶数舍入。
base = floor(v);
remainder = v-base;
increment = (remainder > 0.5) | ...
    ((remainder == 0.5) & (mod(base,2) ~= 0));
q = base+double(increment);
end

function out = round_shift_even(v,shift)
% int64整数的2^shift除法，最近偶数舍入。负shift表示左移。
% 本例范围已检查，int64中间值和最终32位输出均不会溢出。
v = int64(v);
if shift <= 0
    out = v .* bitshift(int64(1),-shift);
    return;
end
divisor = bitshift(int64(1),shift);
base = idivide(v,divisor,'floor');
remainder = v-base.*divisor; % 即使v为负数，余数也在[0,divisor-1]
half = bitshift(divisor,-1);
increment = (remainder > half) | ...
    ((remainder == half) & (mod(base,int64(2)) ~= 0));
out = base+int64(increment);
end

function [out,trace] = round_shift_integer(v,shift,roundingMode,state)
% SR和截断均先向负无穷取整；负数不采用向零截断。
% 该参考只支持0..32位右移，满足本demo的所有输入/系数/输出格式。
assert(isscalar(shift) && shift == floor(shift) && abs(shift) <= 32);
v = int64(v);
trace = struct('shift',shift,'initialState',uint32(state), ...
    'finalState',uint32(state),'drawCount',0,'randomWords',zeros(1,0,'uint32'));
if shift <= 0
    out = v .* bitshift(int64(1),-shift);
elseif strcmp(roundingMode,'sr')
    [words,state] = sr_random_words(state,numel(v));
    trace.randomWords = reshape(words,size(v));
    trace.finalState = state;
    trace.drawCount = numel(v);
    uniform = int64(bitshift(trace.randomWords,shift-32));
    out = sr_round_with_uniform(v,shift,uniform);
elseif strcmp(roundingMode,'rne')
    out = round_shift_even(v,shift);
elseif strcmp(roundingMode,'trunc')
    out = idivide(v,bitshift(int64(1),shift),'floor');
else
    error('Unknown rounding mode.');
end
end

function out = sr_round_with_uniform(v,shift,uniform)
% 以概率D/2^r向上舍入；uniform为r位随机整数，不是0.5概率抛硬币。
divisor = bitshift(int64(1),shift);
assert(all(uniform >= 0 & uniform < divisor,'all'));
base = idivide(int64(v),divisor,'floor');
remainder = int64(v)-base.*divisor;
out = base+int64(uniform < remainder);
end

function [words,state] = sr_random_words(state,count)
% uint64中间计算避免MATLAB的uint32饱和语义；每一步显式模2^32。
% 此LCG用于确定性golden重放，不等同于理想独立随机源或目标硬件实现。
words = zeros(1,count,'uint32');
state = uint32(state);
for i = 1:count
    state = uint32(bitand(uint64(state).*uint64(1664525)+uint64(1013904223), ...
        uint64(2^32-1)));
    words(i) = state;
end
end

function total = sum_integer(v)
total = int64(0);
for i = 1:numel(v)
    total = total+int64(v(i));
end
end

function [productBound,accBound] = check_format(qx,qh,W,Fx)
limit = bitshift(int64(1),W-1);
assert(all(qx >= -limit & qx < limit), '输入整数码超出lane范围。');
assert(all(qh >= -limit & qh < limit), '系数整数码超出lane范围。');
xBound = bitshift(int64(1),Fx); % 原始输入真实范围abs(x)<=1
assert(all(abs(qx) <= xBound), '输入超出本例预设动态范围。');
productBound = xBound .* max(abs(qh));
accBound = xBound .* sum_integer(abs(qh));
assert(productBound < limit, ...
    '原始整数乘积不能放入W位；请降低Fx/Fh或调整输入范围。');
assert(accBound < bitshift(int64(1),31), ...
    '累加上界超出32位；需要重新分配小数位或改变累加策略。');
end

function acc = fir_scalar_integer(qx,qh)
% 原始公式：y[n]=sum_k qh[k]*qx[n-k]，所有抽头均执行。
N = numel(qx);
L = numel(qh);
state = [zeros(1,L-1,'int64'),reshape(qx,1,[])];
acc = zeros(1,N,'int64');
for n = 1:N
    a = int64(0);
    for k = 1:L
        p = state(n+L-k).*qh(k);
        a = a+p;
        assert(a >= int64(-2^31) && a <= int64(2^31-1));
    end
    acc(n) = a;
end
end

function [acc,coeffWords,nInstruction] = fir_simd_integer(qx,qh,W)
% 第n个输出使用state[n:n+L-1]，乘以反序系数。
% 一个抽头组的不同乘积放入不同lane，软件再进行标量求和。
% 这里验证数据行为；ISS仍需统计实现pack的真实加载/移位指令。
N = numel(qx);
L = numel(qh);
lanes = 32/W;
assert(mod(L,lanes) == 0);
state = [zeros(1,L-1,'int64'),reshape(qx,1,[])];
hReverse = qh(end:-1:1);
groups = L/lanes;
coeffWords = zeros(1,groups,'uint32');
for g = 1:groups
    first = (g-1)*lanes+1;
    coeffWords(g) = pack_signed_lanes(hReverse(first:first+lanes-1),W);
end
acc = zeros(1,N,'int64');
nInstruction = 0;
for n = 1:N
    a = int64(0);
    for g = 1:groups
        first = n+(g-1)*lanes;
        inputWord = pack_signed_lanes(state(first:first+lanes-1),W);
        productWord = pmul_low(inputWord,coeffWords(g),W);
        products = unpack_signed_lanes(productWord,W);
        nInstruction = nInstruction+1;
        for lane = 1:lanes
            a = a+products(lane);
            assert(a >= int64(-2^31) && a <= int64(2^31-1));
        end
    end
    acc(n) = a;
end
end

function word = pack_signed_lanes(values,W)
% 将有符号整数转换为W位补码后打包；不能直接uint64(负数)。
lanes = 32/W;
assert(numel(values) == lanes);
limit = 2^(W-1);
assert(all(double(values) >= -limit & double(values) < limit));
word64 = uint64(0);
for lane = 1:lanes
    % 原始值最多32位，double在这里可以精确表示所有整数。
    raw = uint64(mod(double(values(lane)),2^W));
    word64 = bitor(word64,bitshift(raw,(lane-1)*W));
end
word = uint32(word64);
end

function word = pmul_low(A,B,W)
% PMUL行为：每个lane独立相乘，各保留低W位，不产生跨lane乘积。
% 用uint64整数相乘；避免double计算32x32时丢失低位。
% 最大无符号32x32乘积小于uint64上界，因此这里不会饱和。
assert(any(W == [8,16,32]));
mask = bitshift(uint64(1),W)-uint64(1);
word64 = uint64(0);
for lane = 1:32/W
    offset = (lane-1)*W;
    rawA = bitand(bitshift(uint64(A),-offset),mask);
    rawB = bitand(bitshift(uint64(B),-offset),mask);
    lowProduct = bitand(rawA.*rawB,mask);
    word64 = bitor(word64,bitshift(lowProduct,offset));
end
word = uint32(word64);
end

function values = unpack_signed_lanes(word,W)
% 每个lane分别符号扩展，负数不能按无符号数累加。
mask = bitshift(uint64(1),W)-uint64(1);
signBit = bitshift(uint64(1),W-1);
modulus = bitshift(int64(1),W);
values = zeros(1,32/W,'int64');
for lane = 1:32/W
    raw = bitand(bitshift(uint64(word),-(lane-1)*W),mask);
    values(lane) = int64(raw);
    if raw >= signBit
        values(lane) = values(lane)-modulus;
    end
end
end

function snrDB = calculate_snr(reference,actual)
signalPower = sum(reference.^2);
errorPower = sum((reference-actual).^2);
if signalPower == 0
    snrDB = NaN; % 零输入不定义SNR，用绝对误差与功能一致性检查
elseif errorPower == 0
    snrDB = Inf;
else
    snrDB = 10*log10(signalPower/errorPower);
end
end

function tests = run_self_checks
assert(isequal(round_even_double([-2.5,-1.5,-0.5,0.5,1.5,2.5]), ...
    [-2,-2,0,0,2,2]));
assert(isequal(round_shift_even(int64(-9:9),1), ...
    int64([-4,-4,-4,-3,-2,-2,-2,-1,0,0,0,1,2,2,2,3,4,4,4])));
nSRThresholdTests = 0;
for shift = 1:6
    v = int64((-17:17).');
    uniform = int64(0:2^shift-1);
    out = sr_round_with_uniform(v,shift,uniform);
    scaled = double(v)/2^shift;
    assert(all(double(out) >= floor(scaled) & double(out) <= ceil(scaled),'all'));
    % 枚举全部随机阈值：每行输出之和恰好等于v，即均值为v/2^r。
    assert(isequal(sum(double(out),2),double(v)));
    nSRThresholdTests = nSRThresholdTests+numel(out);
end
[words,state] = sr_random_words(uint32(1),4);
assert(isequal(words,uint32([1015568748,1586005467,2165703038,3027450565])));
assert(state == words(end));
[out,trace] = round_shift_integer(int64([3,-3,4,0]),2,'sr',uint32(1));
assert(isequal(out,int64([1,-1,1,0])));
assert(trace.drawCount == 4 && isequal(trace.randomWords,words));
[left,leftTrace] = round_shift_integer(int64([-3,0,3]),-2,'sr',uint32(1));
assert(isequal(left,int64([-12,0,12])) && leftTrace.drawCount == 0);
assert(leftTrace.finalState == uint32(1));
[same,sameTrace] = round_shift_integer(int64([-3,0,3]),0,'sr',uint32(1));
assert(isequal(same,int64([-3,0,3])) && sameTrace.drawCount == 0);
[truncated,~] = round_shift_integer(int64([-3,-1,0,1,3]),1,'trunc',uint32(1));
assert(isequal(truncated,int64([-2,-1,0,0,1])));
rng(20261003,'twister');
nPackTests = 0;
for W = [8,16,32]
    lanes = 32/W;
    edge = int64([-2^(W-1),-1,0,1,2^(W-1)-1]);
    for ai = 1:numel(edge)
        for bi = 1:numel(edge)
            a = edge(mod(ai-1+(0:lanes-1),numel(edge))+1);
            b = edge(mod(bi-1+(0:lanes-1),numel(edge))+1);
            verify_one_pmul(a,b,W);
            nPackTests = nPackTests+1;
        end
    end
    for t = 1:200
        a = int64(randi([-2^(W-1),2^(W-1)-1],1,lanes));
        b = int64(randi([-2^(W-1),2^(W-1)-1],1,lanes));
        verify_one_pmul(a,b,W);
        nPackTests = nPackTests+1;
    end
end
config = [8,3,6;16,7,10;32,15,15];
source = int64([0,1,-1,2047,2048,-2048,-2049,32767,-32768,32768, ...
                127,-127,16384,-16384,8193,-8193,1000]);
nFIRTests = 0;
for L = [16,32,64]
    h = design_lowpass(L,0.1);
    for mi = 1:3
        W = config(mi,1); Fx = config(mi,2); Fh = config(mi,3);
        for rounding = {'sr','rne','trunc'}
            hSource = int64(round_even_double(h*2^31));
            [qh,hTrace] = round_shift_integer(hSource,31-Fh,rounding{1},uint32(W));
            [qx,xTrace] = round_shift_integer(source,15-Fx,rounding{1},hTrace.finalState);
            check_format(qx,qh,W,Fx);
            scalar = fir_scalar_integer(qx,qh);
            simd = fir_simd_integer(qx,qh,W);
            assert(isequal(scalar,simd));
            a = round_shift_integer(scalar,Fx+Fh-15,rounding{1},xTrace.finalState);
            b = round_shift_integer(simd,Fx+Fh-15,rounding{1},xTrace.finalState);
            assert(isequal(a,b));
            nFIRTests = nFIRTests+1;
        end
    end
end
% 非对称系数可发现整体系数反序错误，避免只测试对称低通。
asymmetricX = int64([1,-3,5,0,7,-8,6,2,-1,4,0,3]);
asymmetricH = int64([3,-2,1,4,-1,2,0,5]);
expected = int64(conv(double(asymmetricX),double(asymmetricH)));
expected = expected(1:numel(asymmetricX));
for W = [8,16,32]
    assert(isequal(fir_scalar_integer(asymmetricX,asymmetricH),expected));
    assert(isequal(fir_simd_integer(asymmetricX,asymmetricH,W),expected));
end
tests = struct('PMULCases',nPackTests,'FIRPairs',nFIRTests, ...
    'SRThresholdCases',nSRThresholdTests,'AsymmetricFIRCases',3,'passed',true);
fprintf('Built-in assertions passed: %d PMUL, %d FIR, %d SR thresholds, 3 asymmetric FIR.\n', ...
    nPackTests,nFIRTests,nSRThresholdTests);
end

function verify_one_pmul(a,b,W)
word = pmul_low(pack_signed_lanes(a,W),pack_signed_lanes(b,W),W);
actual = unpack_signed_lanes(word,W);
% 独立参考：完整有符号整数乘法，再计算模2^W并解释为有符号数。
% 32位有符号乘积可用int64精确表示，不能用double计算后再mod。
modulus = bitshift(int64(1),W);
limit = bitshift(int64(1),W-1);
expected = mod(a.*b,modulus);
for k = 1:numel(expected)
    if expected(k) >= limit
        expected(k) = expected(k)-modulus;
    end
end
assert(isequal(actual,expected),'PMUL位模式验证失败。');
end

function show_plots(r)
count = min(r.N,200);
nn = 0:count-1;
colors = lines(3);
figure('Name','FIR with multi-precision low-word multiplication', ...
    'NumberTitle','off','Color','w','Position',[80,60,1250,850]);

subplot(3,2,1);
plot(nn,r.xSource(1:count),'Color',[0.65,0.65,0.65]); hold on;
plot(nn,r.yFloat(1:count),'k','LineWidth',1.2);
grid on; xlabel('Sample'); ylabel('Amplitude');
title('Input and floating-point FIR');
legend('Input','Float FIR','Location','best');

subplot(3,2,2);
plot(0:r.L-1,r.h,'k.-','LineWidth',1.2); hold on;
for mi = 1:3
    plot(0:r.L-1,r.modes(mi).hQuantized,'.-','Color',colors(mi,:));
end
grid on; xlabel('Tap index'); ylabel('Coefficient');
title('Coefficient quantization');
legend('Float','W8','W16','W32','Location','best');

subplot(3,2,3);
fftLength = 4096;
frequency = (0:fftLength/2)/fftLength;
H = fft(r.h,fftLength);
plot(frequency,20*log10(max(abs(H(1:fftLength/2+1)),1e-12)), ...
    'k','LineWidth',1.2); hold on;
for mi = 1:3
    H = fft(r.modes(mi).hQuantized,fftLength);
    plot(frequency,20*log10(max(abs(H(1:fftLength/2+1)),1e-12)), ...
        'Color',colors(mi,:));
end
grid on; xlabel('Frequency / fs'); ylabel('Magnitude (dB)');
title('Frequency response'); ylim([-100,5]);
legend('Float','W8','W16','W32','Location','best');

subplot(3,2,4);
plot(nn,r.yFloat(1:count),'k','LineWidth',1.3); hold on;
for mi = 1:3
    plot(nn,r.modes(mi).y(1:count),'Color',colors(mi,:));
end
grid on; xlabel('Sample'); ylabel('Amplitude');
title('FIR outputs at the same physical scale');
legend('Float','W8','W16','W32','Location','best');

subplot(3,2,5); hold on;
for mi = 1:3
    plot(nn,r.modes(mi).error(1:count),'Color',colors(mi,:));
end
grid on; xlabel('Sample'); ylabel('Fixed - float');
title('Output error'); legend('W8','W16','W32','Location','best');

subplot(3,2,6);
bar([r.modes.snrDB]);
set(gca,'XTick',1:3,'XTickLabel',{'W8','W16','W32'});
grid on; ylabel('SNR (dB)');
title(sprintf('Numerical quality: %s (not speed)',upper(r.roundingMode)));
end
