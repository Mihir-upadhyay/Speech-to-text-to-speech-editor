function dsp_terminal()
%% =====================================================================
%  DSP TERMINAL: command based Speech -> Text -> Edit -> Edited Speech
%  Run by typing   dsp_terminal   in the MATLAB command window.
%  Pure DSP / base MATLAB (no toolbox): short-time energy segmentation,
%  MFCC (pre-emphasis, Hamming, FFT, mel filterbank, DCT), DTW matching,
%  fade / overlap-add joining.   Type  help  at the prompt for commands.
%  =====================================================================
    S = init_state();
    fprintf('\n=========== DSP SPEECH EDITOR (command mode) ===========\n');
    fprintf('Type  help  to see all commands.  Dictionary: %d words.\n', ...
            numel(unique(S.tmplL)));
    if isempty(S.tmplL)
        fprintf('Dictionary is empty. Start with:  add hello please turn on\n');
    end
    while true
        try
            raw = strtrim(input('\ndsp> ', 's'));
        catch
            break;
        end
        if isempty(raw), continue; end
        parts = regexp(lower(raw), '\s+', 'split');
        cmd = parts{1}; args = parts(2:end);
        % allow two-word forms: "add words", "start recording", ...
        if isKey(S.filler, cmd) && ~isempty(args) && strcmp(args{1}, S.filler(cmd))
            args(1) = [];
        end
        try
            switch cmd
                case {'help','?','h'},      print_help();
                case 'add',                 S = cmd_add(S, args);
                case {'words','list'},      cmd_words(S);
                case 'remove',              S = cmd_remove(S, args);
                case 'start',               S = cmd_start(S);
                case {'end','stop'},        S = cmd_end(S);
                case 'load',                S = cmd_load(S, args);
                case 'show',                print_paragraph(S);
                case 'edit',                S = cmd_edit(S, args);
                case 'build',               S = cmd_build(S);
                case 'play',                cmd_play(S, args);
                case 'export',              cmd_export(S);
                case 'set',                 S = cmd_set(S, args);
                case 'status',              cmd_status(S);
                case {'quit','exit','q'}
                    if S.isRec, stop(S.recObj); end
                    fprintf('Bye.\n'); return;
                otherwise
                    fprintf('Unknown command "%s". Type  help.\n', cmd);
            end
        catch ME
            fprintf('Error: %s\n', ME.message);
        end
    end
end

%% ===================== STATE =========================================
function S = init_state()
    S.fs = 16000;  S.reps = 2;  S.enrollSecs = 1.5;
    S.sentGap = 700;  S.rejectFactor = 3;
    S.cfgEnroll = struct('minLen_ms',100,'maxGap_ms',150,'thrFactor',3,'thrFloor',0.001);
    S.cfgPara   = struct('minLen_ms',100,'maxGap_ms',50, 'thrFactor',3,'thrFloor',0.001);
    S.tmplF = {};  S.tmplL = {};  S.rejectThr = Inf;
    if exist('templates.mat','file')
        L = load('templates.mat');
        S.tmplF = L.tmplF;  S.tmplL = L.tmplL;
    end
    S = update_threshold(S);
    S.isRec = false;  S.recObj = [];
    S.hasPara = false;  S.x = [];  S.segs = [];  S.rec = {};
    S.lineOf = [];  S.wordAudio = {};  S.keep = [];
    S.hasY = false;  S.Y = {};  S.best = 0;  S.buildCount = 0;
    S.filler = containers.Map( ...
        {'add','start','end','stop','edit','show','list'}, ...
        {'words','recording','recording','recording','paragraph','paragraph','words'});
end

function S = update_threshold(S)
    % rejection threshold from distances between samples of the same word
    intra = [];  labs = unique(S.tmplL);
    for i = 1:numel(labs)
        idx = find(strcmp(S.tmplL, labs{i}));
        for a = 1:numel(idx)-1
            for b = a+1:numel(idx)
                intra(end+1) = dtw_dist(S.tmplF{idx(a)}, S.tmplF{idx(b)}); %#ok<AGROW>
            end
        end
    end
    if isempty(intra) || isinf(S.rejectFactor)
        S.rejectThr = Inf;
    else
        S.rejectThr = S.rejectFactor * mean(intra);
    end
end

function save_templates(S)
    tmplF = S.tmplF;  tmplL = S.tmplL; %#ok<NASGU>
    save('templates.mat', 'tmplF', 'tmplL');
end

%% ===================== HELP / STATUS =================================
function print_help()
    fprintf('\n--------------------------- COMMANDS ---------------------------\n');
    fprintf(' DICTIONARY\n');
    fprintf('  add <w1> <w2> ..     type new word(s), then record voice samples\n');
    fprintf('  words                list dictionary words and sample counts\n');
    fprintf('  remove <w1> ..       delete word(s) from the dictionary\n');
    fprintf(' RECORDING\n');
    fprintf('  start                start recording from the mic (start recording)\n');
    fprintf('  end                  stop recording + convert speech to text (end recording)\n');
    fprintf('  load <file.wav>      convert an existing wav file instead of the mic\n');
    fprintf(' PARAGRAPH\n');
    fprintf('  show                 show paragraph with word numbers\n');
    fprintf('  edit                 open edit box, delete words/lines (edit paragraph)\n');
    fprintf('  edit del 3 5-7 the   delete by word number, range or word\n');
    fprintf('  edit del line 2      delete a whole line (sentence)\n');
    fprintf('  edit reset           bring all words back\n');
    fprintf('  build                make 5 edited versions, score + plot them\n');
    fprintf('  play <1-5|best|all|original>   play a version\n');
    fprintf('  export               save original/edited text to .txt files\n');
    fprintf(' OTHER\n');
    fprintf('  set                  show settings;  set <name> <value> to change\n');
    fprintf('                       names: reps secs sentgap reject thr maxgap\n');
    fprintf('  status               show current state\n');
    fprintf('  help / quit\n');
    fprintf('-----------------------------------------------------------------\n');
end

function cmd_status(S)
    fprintf('\nDictionary : %d words, %d samples\n', numel(unique(S.tmplL)), numel(S.tmplL));
    fprintf('Recording  : %s\n', ternary(S.isRec, 'ON (type "end")', 'off'));
    if S.hasPara
        fprintf('Paragraph  : %d words, %d kept, %d lines\n', ...
                numel(S.rec), nnz(S.keep), max(S.lineOf));
    else
        fprintf('Paragraph  : none yet\n');
    end
    fprintf('Versions   : %s\n', ternary(S.hasY, sprintf('built (best = V%d)', S.best), 'not built'));
end

function r = ternary(c, a, b)
    if c, r = a; else, r = b; end
end

%% ===================== DICTIONARY COMMANDS ===========================
function S = cmd_add(S, args)
    if S.isRec, fprintf('Recording is running - type "end" first.\n'); return; end
    if isempty(args)
        s = strtrim(input('Word(s) to add (space separated): ', 's'));
        if isempty(s), return; end
        args = regexp(lower(s), '\s+', 'split');
    end
    for w = 1:numel(args)
        word = args{w};
        if isempty(regexp(word, '^[a-z0-9'']+$', 'once'))
            fprintf('Skipping "%s" (use letters/digits only).\n', word); continue;
        end
        if any(strcmp(S.tmplL, word))
            fprintf('"%s" already exists - adding extra samples.\n', word);
        end
        got = 0;
        while got < S.reps
            fprintf('\n[%s] sample %d/%d\n', word, got+1, S.reps);
            reply = strtrim(input('Press Enter, then say the word (c = cancel this word): ', 's'));
            if strcmpi(reply, 'c'), fprintf('Cancelled "%s".\n', word); break; end
            [F, msg] = record_word_sample(S);
            if isempty(F), fprintf('  %s Try again.\n', msg); continue; end
            S.tmplF{end+1} = F;  S.tmplL{end+1} = word;  got = got + 1;
            fprintf('  Sample saved.\n');
        end
    end
    S = update_threshold(S);
    save_templates(S);
    fprintf('\nDictionary now has %d words (%d samples).\n', ...
            numel(unique(S.tmplL)), numel(S.tmplL));
end

function [F, msg] = record_word_sample(S)
    F = [];  msg = '';
    r = audiorecorder(S.fs, 16, 1);
    fprintf('  Speak now...\n');
    recordblocking(r, S.enrollSecs);
    x = getaudiodata(r);  x = x(:) - mean(x);
    if max(abs(x)) < 0.02, msg = 'Too quiet / no speech.'; return; end
    segs = segment_words(x, S.fs, S.cfgEnroll);
    if isempty(segs), msg = 'No word detected.'; return; end
    [~, i] = max(segs(:,2) - segs(:,1));            % longest sound = the word
    F = mfcc_feat(x(segs(i,1):segs(i,2)), S.fs);
end

function cmd_words(S)
    labs = unique(S.tmplL);
    if isempty(labs), fprintf('Dictionary is empty. Use:  add <word>\n'); return; end
    fprintf('\nDictionary (%d words, %d samples):\n', numel(labs), numel(S.tmplL));
    for i = 1:numel(labs)
        fprintf('  %-14s %d sample(s)\n', labs{i}, nnz(strcmp(S.tmplL, labs{i})));
    end
end

function S = cmd_remove(S, args)
    if isempty(args), fprintf('Usage: remove <word> [word ...]\n'); return; end
    for w = 1:numel(args)
        idx = strcmp(S.tmplL, args{w});
        if ~any(idx), fprintf('"%s" is not in the dictionary.\n', args{w}); continue; end
        S.tmplF(idx) = [];  S.tmplL(idx) = [];
        fprintf('Removed "%s".\n', args{w});
    end
    S = update_threshold(S);
    save_templates(S);
end

%% ===================== RECORDING COMMANDS ============================
function S = cmd_start(S)
    if isempty(S.tmplL)
        fprintf('Dictionary is empty. Use:  add <word>  first.\n'); return;
    end
    if S.isRec, fprintf('Already recording. Type "end" to finish.\n'); return; end
    S.recObj = audiorecorder(S.fs, 16, 1);
    record(S.recObj);
    S.isRec = true;
    fprintf('Recording... speak now, then type  end.\n');
    fprintf('(short pause between words, about %.1f s between sentences)\n', S.sentGap/1000);
end

function S = cmd_end(S)
    if ~S.isRec, fprintf('Not recording. Type "start" first.\n'); return; end
    stop(S.recObj);  S.isRec = false;
    x = getaudiodata(S.recObj);
    audiowrite('paragraph.wav', x, S.fs);
    fprintf('Recording stopped (%.1f s, saved as paragraph.wav).\n', numel(x)/S.fs);
    S = process_audio(S, x);
end

function S = cmd_load(S, args)
    if isempty(args), fprintf('Usage: load <file.wav>\n'); return; end
    fname = args{1};
    if ~exist(fname, 'file'), fprintf('File "%s" not found.\n', fname); return; end
    if isempty(S.tmplL), fprintf('Dictionary is empty. Use:  add <word>  first.\n'); return; end
    [x, f] = audioread(fname);  x = x(:,1);
    if f ~= S.fs
        x = interp1((0:numel(x)-1)'/f, x, (0:1/S.fs:(numel(x)-1)/f)');
    end
    S = process_audio(S, x);
end

function S = process_audio(S, x)
    x = x(:) - mean(x);
    if numel(x) < 0.3*S.fs || max(abs(x)) < 0.01
        fprintf('No speech found in the recording.\n'); return;
    end
    fprintf('Recognising (takes a few seconds)...\n');
    segs = segment_words(x, S.fs, S.cfgPara);
    nW = size(segs, 1);
    if nW == 0
        fprintf('No words detected. Speak louder or try:  set thr 2\n'); return;
    end
    rec = cell(1, nW);  wordAudio = cell(1, nW);
    for k = 1:nW
        wordAudio{k} = x(segs(k,1):segs(k,2));
        F = mfcc_feat(wordAudio{k}, S.fs);
        d = cellfun(@(T) dtw_dist(F, T), S.tmplF);
        [dmin, i] = min(d);
        if dmin > S.rejectThr, rec{k} = '<?>'; else, rec{k} = S.tmplL{i}; end
    end
    lineOf = ones(1, nW);  ln = 1;                   % new line at long pauses
    for k = 1:nW-1
        if (segs(k+1,1) - segs(k,2)) / S.fs * 1000 > S.sentGap, ln = ln + 1; end
        lineOf(k+1) = ln;
    end
    S.x = x;  S.segs = segs;  S.rec = rec;  S.lineOf = lineOf;
    S.wordAudio = wordAudio;  S.keep = true(1, nW);
    S.hasPara = true;  S.hasY = false;
    print_paragraph(S);

    figure(1); clf; set(gcf, 'Name', 'Recorded paragraph');
    plot((0:numel(x)-1)/S.fs, x); hold on;
    for i = 1:nW
        xline(segs(i,1)/S.fs, 'g'); xline(segs(i,2)/S.fs, 'r');
        text(mean(segs(i,:))/S.fs, 0.95*max(abs(x)), rec{i}, ...
             'Rotation', 90, 'FontSize', 8, 'HorizontalAlignment', 'right');
    end
    title('Paragraph with detected words'); xlabel('Time (s)'); grid on;
end

%% ===================== PARAGRAPH COMMANDS ============================
function print_paragraph(S)
    if ~S.hasPara
        fprintf('No paragraph yet. Use  start / end  (or  load file.wav).\n'); return;
    end
    fprintf('\n--- PARAGRAPH (%d words, %d kept) ---\n', numel(S.rec), nnz(S.keep));
    for ln = 1:max(S.lineOf)
        idx = find(S.lineOf == ln);  parts = cell(1, numel(idx));
        for q = 1:numel(idx)
            i = idx(q);
            if S.keep(i), parts{q} = sprintf('%d:%s', i, S.rec{i});
            else,         parts{q} = sprintf('%d:~%s~', i, S.rec{i}); end
        end
        fprintf('line %d | %s\n', ln, strjoin(parts, '  '));
    end
    fprintf('Current text: %s\n', strjoin(S.rec(S.keep), ' '));
    fprintf('(~word~ = deleted,  <?> = not recognised)\n');
end

function S = cmd_edit(S, args)
    if ~S.hasPara, fprintf('No paragraph yet. Use  start / end  first.\n'); return; end
    nW = numel(S.rec);

    if isempty(args)                                  % ---- edit box ----
        kidx = find(S.keep);
        if isempty(kidx), fprintf('All words deleted. Use  edit reset.\n'); return; end
        lns = {};
        for ln = 1:max(S.lineOf)
            idx = kidx(S.lineOf(kidx) == ln);
            if ~isempty(idx), lns{end+1} = strjoin(S.rec(idx), ' '); end %#ok<AGROW>
        end
        try
            answer = inputdlg({'Edit paragraph: delete words or lines (do not add or reorder words).'}, ...
                              'Edit paragraph', [12 70], {char(lns)});
            if isempty(answer), fprintf('Edit cancelled.\n'); return; end
            edTxt = strjoin(cellstr(answer{1})', ' ');
        catch
            fprintf('Current text: %s\n', strjoin(S.rec(kidx), ' '));
            edTxt = input('Type the edited text: ', 's');
        end
        ed = regexp(strtrim(lower(edTxt)), '\s+', 'split');
        if isequal(ed, {''}), ed = {}; end
        newKeep = false(1, numel(kidx));  j = 1;
        for q = 1:numel(kidx)
            if j <= numel(ed) && strcmp(S.rec{kidx(q)}, ed{j})
                newKeep(q) = true;  j = j + 1;
            end
        end
        if j <= numel(ed)
            fprintf('Note: some typed words were ignored (only deletions are supported).\n');
        end
        S.keep(kidx) = newKeep;

    elseif strcmp(args{1}, 'reset')                   % ---- reset ----
        S.keep(:) = true;
        fprintf('All words restored.\n');

    elseif any(strcmp(args{1}, {'del','delete'}))     % ---- delete ----
        toks = args(2:end);
        if isempty(toks)
            fprintf('Usage: edit del 3 5-7 the   |   edit del line 2\n'); return;
        end
        before = nnz(S.keep);
        if strcmp(toks{1}, 'line')
            for t = 2:numel(toks)
                ln = str2double(toks{t});
                if ~isnan(ln), S.keep(S.lineOf == ln) = false; end
            end
        else
            for t = 1:numel(toks)
                tok = toks{t};
                rg = regexp(tok, '^(\d+)-(\d+)$', 'tokens', 'once');
                if ~isempty(rg)
                    ids = str2double(rg{1}):str2double(rg{2});
                elseif ~isnan(str2double(tok))
                    ids = str2double(tok);
                else
                    S.keep(strcmp(S.rec, tok)) = false;  continue;   % by word
                end
                ids = ids(ids >= 1 & ids <= nW & ids == round(ids));
                S.keep(ids) = false;
            end
        end
        fprintf('Deleted %d word(s).\n', before - nnz(S.keep));
    else
        fprintf('Unknown edit option. Use:  edit | edit del ... | edit reset\n'); return;
    end
    print_paragraph(S);
    fprintf('Next: type  build  to create the 5 edited versions.\n');
end

function cfgs = get_cfgs()
    cfgs(1) = struct('name','V1 Raw cut',             'fade',0,  'pause',0,   'norm',false);
    cfgs(2) = struct('name','V2 Raw + pause',         'fade',0,  'pause',120, 'norm',false);
    cfgs(3) = struct('name','V3 Crossfade',           'fade',10, 'pause',0,   'norm',false);
    cfgs(4) = struct('name','V4 Fade + pause',        'fade',10, 'pause',120, 'norm',false);
    cfgs(5) = struct('name','V5 Fade+pause+loudness', 'fade',10, 'pause',120, 'norm',true);
end

function S = cmd_build(S)
    if ~S.hasPara, fprintf('No paragraph yet. Use  start / end  first.\n'); return; end
    if ~any(S.keep), fprintf('All words are deleted. Use  edit reset.\n'); return; end
    cfgs = get_cfgs();
    kept = S.wordAudio(S.keep);
    S.buildCount = S.buildCount + 1;
    Y = cell(1,5);  score = zeros(1,5);  M = cell(1,5);
    for v = 1:5
        [Y{v}, wS, wE] = build_variant(kept, S.fs, cfgs(v));
        M{v} = evaluate(Y{v}, wS, wE, S.fs);
        gapPenalty = 0.2 * (cfgs(v).pause == 0);
        score(v) = M{v}.click + 0.05*M{v}.loudStd + gapPenalty;      % lower = better
        audiowrite(sprintf('build%d_V%d.wav', S.buildCount, v), Y{v}/max(abs(Y{v}))*0.9, S.fs);
    end
    [~, best] = min(score);
    S.Y = Y;  S.best = best;  S.hasY = true;

    fprintf('\nText used: %s\n\n', strjoin(S.rec(S.keep), ' '));
    fprintf('%-24s %-10s %-12s %-9s %-7s\n', 'Version','Click','LoudStd(dB)','Dur(s)','Score');
    for v = 1:5
        fprintf('%-24s %-10.3f %-12.2f %-9.2f %-7.3f\n', cfgs(v).name, ...
                M{v}.click, M{v}.loudStd, M{v}.dur, score(v));
    end
    fprintf('\nBest version by objective score: %s\n', cfgs(best).name);
    fprintf('Saved as build%d_V1.wav ... build%d_V5.wav.  Listen with:  play <1-5|best|all>\n', ...
            S.buildCount, S.buildCount);

    figure(2); clf; set(gcf, 'Name', 'Edited versions');
    for v = 1:5
        subplot(5,1,v); plot((0:numel(Y{v})-1)/S.fs, Y{v});
        title(sprintf('%s   (score %.3f)', cfgs(v).name, score(v))); grid on; ylabel('Amp');
    end
    xlabel('Time (s)');
    figure(3); clf; set(gcf, 'Name', 'Score comparison');
    bar(score); set(gca, 'XTickLabel', {'V1','V2','V3','V4','V5'});
    ylabel('Score (lower = better)'); title('Version comparison'); grid on;
end

function cmd_play(S, args)
    cfgs = get_cfgs();
    if isempty(args)
        if S.hasY, args = {'best'}; else, fprintf('Usage: play <1-5|best|all|original>\n'); return; end
    end
    arg = args{1};
    if strcmp(arg, 'original')
        if ~S.hasPara, fprintf('No paragraph yet.\n'); return; end
        fprintf('Playing original recording...\n');
        sound(S.x / max(abs(S.x)) * 0.9, S.fs);  pause(numel(S.x)/S.fs + 0.3);
        return;
    end
    if ~S.hasY, fprintf('No versions yet. Type  build  first.\n'); return; end
    switch arg
        case 'all',  list = 1:5;
        case 'best', list = S.best;
        otherwise
            n = str2double(arg);
            if isnan(n) || n < 1 || n > 5 || n ~= round(n)
                fprintf('Usage: play <1-5|best|all|original>\n'); return;
            end
            list = n;
    end
    for v = list
        fprintf('Playing %s ...\n', cfgs(v).name);
        y = S.Y{v};  sound(y / max(abs(y)) * 0.9, S.fs);  pause(numel(y)/S.fs + 0.4);
    end
end

function cmd_export(S)
    if ~S.hasPara, fprintf('No paragraph yet.\n'); return; end
    fid = fopen('paragraph_original.txt', 'w');
    fprintf(fid, '%s\n', strjoin(S.rec, ' '));  fclose(fid);
    fid = fopen('paragraph_edited.txt', 'w');
    fprintf(fid, '%s\n', strjoin(S.rec(S.keep), ' '));  fclose(fid);
    fprintf('Saved paragraph_original.txt and paragraph_edited.txt\n');
end

%% ===================== SETTINGS ======================================
function S = cmd_set(S, args)
    if numel(args) < 2
        fprintf('\nSettings (change with: set <name> <value>)\n');
        fprintf('  reps      %d     samples recorded per word when adding\n', S.reps);
        fprintf('  secs      %.1f   recording time per word sample (s)\n', S.enrollSecs);
        fprintf('  sentgap   %d   pause (ms) that starts a new line\n', S.sentGap);
        fprintf('  reject    %g     higher = fewer <?>  (inf = never reject)  [threshold %.2f]\n', ...
                S.rejectFactor, S.rejectThr);
        fprintf('  thr       %g     word detection threshold factor (lower = more sensitive)\n', ...
                S.cfgPara.thrFactor);
        fprintf('  maxgap    %d    gap (ms) below which sounds merge into one word\n', ...
                S.cfgPara.maxGap_ms);
        return;
    end
    val = str2double(args{2});
    if isnan(val), fprintf('Value must be a number.\n'); return; end
    switch args{1}
        case 'reps',    S.reps = max(1, round(val));
        case 'secs',    S.enrollSecs = val;
        case 'sentgap', S.sentGap = val;
        case 'reject',  S.rejectFactor = val;  S = update_threshold(S);
        case 'thr',     S.cfgPara.thrFactor = val;  S.cfgEnroll.thrFactor = val;
        case 'maxgap',  S.cfgPara.maxGap_ms = val;
        otherwise, fprintf('Unknown setting "%s".\n', args{1}); return;
    end
    fprintf('Set %s = %g\n', args{1}, val);
end

%% ===================== DSP FUNCTIONS =================================
function [segs, E, thr] = segment_words(x, fs, cfg)
    % Short-time energy based word detection
    x = x(:); x = x / max(abs(x));
    fl = round(0.025*fs); hop = round(0.010*fs);
    nf = floor((length(x)-fl)/hop) + 1;
    E = zeros(nf,1);
    for i = 1:nf
        fr = x((i-1)*hop + (1:fl));
        E(i) = sum(fr.^2);
    end
    E = E / max(E);
    Es = sort(E); noise = mean(Es(1:max(1,round(0.1*nf))));
    thr = max(cfg.thrFactor*noise, cfg.thrFloor);
    active = E > thr;
    d  = diff([0; active; 0]);
    st = find(d == 1); en = find(d == -1) - 1;
    if isempty(st), segs = zeros(0,2); return; end
    maxGap = round(cfg.maxGap_ms/10); minLen = round(cfg.minLen_ms/10);
    Sg = []; cs = st(1); ce = en(1);
    for i = 2:numel(st)
        if st(i) - ce <= maxGap
            ce = en(i);
        else
            Sg = [Sg; cs ce]; cs = st(i); ce = en(i); %#ok<AGROW>
        end
    end
    Sg = [Sg; cs ce];
    Sg = Sg(Sg(:,2)-Sg(:,1)+1 >= minLen, :);
    pad = 2;                                   % 20 ms safety margin
    a = max(1, (Sg(:,1)-1)*hop + 1 - pad*hop);
    b = min(length(x), (Sg(:,2)-1)*hop + fl + pad*hop);
    segs = [a b];
end

function F = mfcc_feat(x, fs)
    x = x(:); x = filter([1 -0.97], 1, x);     % pre-emphasis
    fl = round(0.025*fs); hop = round(0.010*fs);
    nfft = 512; nm = 20; nc = 12;
    if length(x) < fl, x = [x; zeros(fl-length(x),1)]; end
    w  = 0.54 - 0.46*cos(2*pi*(0:fl-1)'/(fl-1));    % Hamming window
    nf = floor((length(x)-fl)/hop) + 1;
    H  = melbank(nm, nfft, fs);
    n  = 1:nm; C = zeros(nc, nm);
    for k = 1:nc, C(k,:) = cos(pi*k*(n-0.5)/nm); end % DCT-II
    F = zeros(nf, nc);
    for i = 1:nf
        fr = x((i-1)*hop + (1:fl)) .* w;
        P  = abs(fft(fr, nfft)).^2; P = P(1:nfft/2+1);
        F(i,:) = (C * log(H*P + eps))';
    end
    F = F - mean(F, 1);                         % cepstral mean normalisation
end

function H = melbank(nm, nfft, fs)
    mel  = @(f) 2595*log10(1 + f/700);
    imel = @(m) 700*(10.^(m/2595) - 1);
    pts  = imel(linspace(mel(0), mel(fs/2), nm+2));
    bins = floor((nfft+1)*pts/fs) + 1;
    nb = nfft/2 + 1; H = zeros(nm, nb);
    for m = 1:nm
        l = bins(m); c = bins(m+1); r = min(bins(m+2), nb);
        for k = l:c, H(m,k) = (k-l)/max(c-l,1); end
        for k = c:r, H(m,k) = (r-k)/max(r-c,1); end
    end
end

function d = dtw_dist(A, B)
    n = size(A,1); m = size(B,1);
    C = sqrt(max(bsxfun(@plus, sum(A.^2,2), sum(B.^2,2)') - 2*(A*B'), 0));
    D = inf(n+1, m+1); D(1,1) = 0;
    for i = 1:n
        for j = 1:m
            D(i+1,j+1) = C(i,j) + min(min(D(i,j+1), D(i+1,j)), D(i,j));
        end
    end
    d = D(n+1, m+1) / (n + m);
end

function [y, wS, wE] = build_variant(words, fs, cfg)
    y = []; wS = zeros(1,numel(words)); wE = wS;
    nf = round(cfg.fade*fs/1000);
    for i = 1:numel(words)
        s = words{i}(:);
        if cfg.norm, s = s * 0.1 / (sqrt(mean(s.^2)) + eps); end
        if nf > 1 && numel(s) > 2*nf
            r = 0.5*(1 - cos(pi*(0:nf-1)'/(nf-1)));   % raised-cosine fade
            s(1:nf)         = s(1:nf) .* r;
            s(end-nf+1:end) = s(end-nf+1:end) .* flipud(r);
        end
        if isempty(y)
            wS(i) = 1; y = s;
        elseif cfg.pause > 0
            y = [y; zeros(round(cfg.pause*fs/1000),1)]; %#ok<AGROW>
            wS(i) = numel(y) + 1; y = [y; s];           %#ok<AGROW>
        elseif nf > 1
            wS(i) = numel(y) - nf + 1;                  % overlap-add join
            y(end-nf+1:end) = y(end-nf+1:end) + s(1:nf);
            y = [y; s(nf+1:end)];                       %#ok<AGROW>
        else
            wS(i) = numel(y) + 1; y = [y; s];           %#ok<AGROW>
        end
        wE(i) = numel(y);
    end
end

function m = evaluate(y, wS, wE, fs)
    w  = round(0.002*fs);
    dy = [0; abs(diff(y))];
    mx = 0;
    for p = unique([wS wE])
        a = max(1, p-w); b = min(numel(y), p+w);
        mx = max(mx, max(dy(a:b)));
    end
    m.click   = mx / max(abs(y));                 % click / discontinuity at joins
    lv = arrayfun(@(a,b) 20*log10(sqrt(mean(y(a:b).^2)) + eps), wS, wE);
    m.loudStd = std(lv);                          % loudness consistency (dB)
    m.dur     = numel(y) / fs;
end