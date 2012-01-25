function model = train(name, model, pos, neg, warp, randneg, iter, ...
                       negiter, maxnum, keepsv, overlap, cont, phase, C, J)

% model = train(name, model, pos, neg, warp, randneg, iter,
%               negiter, maxsize, keepsv, overlap, cont, C, J)
% Train LSVM.
%
% warp=1 uses warped positives
% warp=0 uses latent positives
% randneg=1 uses random negaties
% randneg=0 uses hard negatives
% iter is the number of training iterations
% negiter is the number of data-mining steps within each training iteration
% maxnum is the maximum number of negative examples to put in the training data file
% keepsv=true keeps support vectors between iterations
% overlap is the minimum overlap in latent positive search
% cont=true we restart training from a previous run
% C & J are the parameters for LSVM objective function

if nargin < 9
  maxnum = 24000;
end

if nargin < 10
  keepsv = false;
end

if nargin < 11
  overlap = 0.7;
end

if nargin < 12
  cont = false;
end

if nargin < 13
  phase = '0';
end

if nargin < 14
  % magic constant estimated from models that perform well in practice
  C = 0.002;
end

if nargin < 15
  J = 1;
end

maxnum = max(length(pos)*10, maxnum+length(pos));
% 3GB file limit
bytelimit = 1.5*2^31;

globals;

negpos = 0;     % last position in data mining

if ~cont
  fv_cache('init', maxnum);
end

datamine = true;
pos_loss = zeros(iter,2);
for t = 1:iter
  fprintf('%s iter: %d/%d\n', procid(), t, iter);
  % label, score, is_unqiue, dataid, x, y, scale, byte size
  info    = fv_cache('info');
  labels  = info(:, 1);
  vals    = info(:, 2);
  unique  = info(:, 3);
  num     = length(labels);
  
  if ~cont || t > 1
    % compute loss on positives before relabeling
    if warp == 0
      I = find(labels == 1);
      pos_vals = vals(I);
      hinge = max(0, 1-pos_vals);
      pos_loss(t,1) = J*C*sum(hinge);
    end
  
    % remove old positives
    I = sort(find(labels == -1));
    fv_cache('shrink', int32(I));
    num = length(I);

    % add new positives
    if warp > 0
      numadded = poswarp(name, t, model, warp, pos);
      fusage = numadded;
    else
      [numadded, fusage, scores] = poslatent(name, t, iter, model, pos, overlap);
    end
    num = num + numadded;

    % save positive filter usage statistics
    model.fusage = fusage;
    fprintf('\nFilter usage stats:\n');
    for i = 1:model.numfilters
      fprintf('  filter %d got %d/%d (%.2f%%) positives\n', ...
              i, fusage(i), numadded, 100*fusage(i)/numadded);
    end

    % compute loss on positives after relabeling
    if warp == 0
      hinge = max(0, 1-scores);
      pos_loss(t,2) = J*C*sum(hinge);
      for tt = 1:t
        fprintf('positive loss before: %f, after: %f, ratio: %f\n', ...
                pos_loss(tt,1), pos_loss(tt,2), pos_loss(tt,2)/pos_loss(tt,1));
      end
      if t > 1 && pos_loss(t,2) > pos_loss(t,1)
        fprintf('warning: pos loss went up\n');
        keyboard;
      end
      % stop if relabeling doesn't reduce the positive loss by much
      if (t > 1) && (pos_loss(t,2)/pos_loss(t,1) > 0.999)
        break;
      end
    end
  end
  
  % data mine negatives
  cache = zeros(negiter,4);
  neg_loss = zeros(negiter,1);
  neg_comp = zeros(negiter,1);
  for tneg = 1:negiter
    fprintf('%s iter: %d/%d, neg iter %d/%d\n', procid(), t, iter, tneg, negiter);
       
    if datamine
      % add new negatives
      if randneg > 0
        numadded = negrandom(name, t, model, randneg, neg, maxnum-num); 
        num = num + numadded;
        randneg = randneg - 1;
        fusage = numadded;
      else
        [numadded, negpos, fusage, scores, complete] = ...
            neghard(name, tneg, negiter, model, neg, bytelimit, ...
                    negpos, maxnum-num);
        num = num + numadded;
        hinge = max(0, 1+scores);
        neg_loss(tneg) = C*sum(hinge);
        neg_comp(tneg) = complete;
        fprintf('complete: %d, negative loss of old model: %f\n', ...
                neg_comp(tneg), neg_loss(tneg,1));
        for tt = 2:tneg
          cache_val = cache(tt-1,4);
          full_val = cache(tt-1,4)-cache(tt-1,1) + neg_loss(tt);
          fprintf('obj on cache: %f, obj on full: %f, ratio %f\n', ...
                  cache_val, full_val, full_val/cache_val);
        end
      end

      fprintf('\nFilter usage stats:\n');
      for i = 1:model.numfilters
        fprintf('  filter %d got %d/%d (%.2f%%) negatives\n', ...
                i, fusage(i), numadded, 100*fusage(i)/numadded);
      end
      
      if randneg == 0 && tneg > 1 && neg_comp(tneg)
        cache_val = cache(tneg-1,4);
        full_val = cache(tneg-1,4)-cache(tneg-1,1) + neg_loss(tneg);
        if full_val/cache_val < 1.05
          fprintf('Data mining convergence condition met.\n');
          datamine = false;
          break;
        end
      end
    else
      fprintf('Skipping data mining iteration.\n');
      fprintf('The model has not changed since the last data mining iteration.\n');
      datamine = true;
    end

    pool_size = close_parallel_pool();
    
    % learn model
    logtag = [name '_' phase '_' num2str(t) '_' num2str(tneg)];
    [blocks, lb, rm, lm, cmps] = fv_model_args(model);
    fv_cache('set_model', blocks, lb, rm, lm, cmps, C, J);
    % optimize with SGD
    [nl, pl, rt, status] = fv_cache('sgd', cachedir, logtag);
    if status ~= 0
      fprintf('parameter learning interrupted\n');
      keyboard;
    end

    fprintf('parsing model\n');
    blocks = fv_cache('get_model');
    model = parsemodel(model, blocks);

    cache(tneg,:) = [nl pl rt nl+pl+rt];
    for tt = 1:tneg
      fprintf('cache objective, neg: %f, pos: %f, reg: %f, total: %f\n', ...
              cache(tt,1), cache(tt,2), cache(tt,3), cache(tt,4));
    end

    % label, score, is_unqiue, dataid, x, y, scale, byte size
    info    = fv_cache('info');
    labels  = info(:, 1);
    vals    = info(:, 2);
    unique  = info(:, 3);
    
    % compute threshold for high recall
    P = find((labels == 1) .* unique);
    pos_vals = sort(vals(P));
    model.thresh = pos_vals(ceil(length(pos_vals)*0.05));
    pos_sv = numel(find(pos_vals < 1));

    % cache model
    save([cachedir name '_model_' phase '_' num2str(t) '_' num2str(tneg)], 'model');

    % keep negative support vectors?
    neg_sv = 0;
    if keepsv
      % compute max number of elements that could fit into cache based
      % on average element size
      byte_size = fv_cache('byte_size');
      % bytes per example
      exsz = byte_size/length(labels);
      % estimated number of examples that will fit in the cache
      % respecting the byte limit
      maxcachesize = min(maxnum, round(bytelimit/exsz));
      U = find((labels == -1) .* unique);
      V = vals(U);
      [ignore, S] = sort(-V);
      % keep the cache at least half full
      sv = round((maxcachesize-length(P))/2);
      % but make sure to include all negative support vectors
      neg_sv = numel(find(V > -1));
      sv = max(sv, neg_sv);
      if length(S) > sv
        S = S(1:sv);
      end
      N = U(S);
    else
      N = [];
    end    
    fprintf('shrinking cache\n');
    I = sort([P; N]);
    fv_cache('shrink', int32(I));
    num = length(I);    
    fprintf('cached %d positive and %d negative examples\n', ...
            length(P), length(N));    
    % # neg SVs overcounts because it's counting feature vectors
    % not examples
    fprintf('# neg SVs: %d\n# pos SVs: %d\n', neg_sv, pos_sv);

    % Sanity check
    info    = fv_cache('info');
    labels  = info(:, 1);
    assert(length(find(labels == +1)) == length(P));
    assert(length(find(labels == -1)) == length(N));   

    % Reopen parallel pool (if applicable)
    reopen_parallel_pool(pool_size);
  end
end

% get positive examples by warping positive bounding boxes
% we create virtual examples by flipping each image left to right
function num = poswarp(name, t, model, ind, pos)
% assumption: the model only has a single structure rule 
% of the form Q -> F.
globals;
numpos = length(pos);
warped = warppos(model, pos);
fi = model.symbols(model.rules{model.start}.rhs).filter;
fbl = model.filters(fi).blocklabel;
obl = model.rules{model.start}.offset.blocklabel;
width1 = ceil(model.filters(fi).size(2)/2);
width2 = floor(model.filters(fi).size(2)/2);
pixels = model.filters(fi).size * model.sbin;
minsize = prod(pixels);
num = 0;
for i = 1:numpos
  fprintf('%s %s: iter %d: warped positive: %d/%d\n', procid(), name, t, i, numpos);
  bbox = [pos(i).x1 pos(i).y1 pos(i).x2 pos(i).y2];
  % skip small examples
  if (bbox(3)-bbox(1)+1)*(bbox(4)-bbox(2)+1) < minsize
    continue
  end    
  % get example
  im = warped{i};
  feat = features(im, model.sbin);
  % + 3 for the 2 blocklabels + 1-dim offset
  dim = numel(feat) + 3;
  key = [1 i 0 0 0];
  fv = [obl; 1; fbl; feat(:)];
  fv_cache('add', int32(key), 2, dim, single(fv)); 
  num = num+1;
end


% get positive examples using latent detections
% we create virtual examples by flipping each image left to right
function [num, fusage, scores] ...
  = poslatent(name, t, iter, model, pos, overlap)
numpos = length(pos);
model.interval = 5;
pixels = model.minsize * model.sbin;
minsize = prod(pixels);
fusage = zeros(model.numfilters, 1);
num = 0;
batchsize = max(1, try_get_matlabpool_size());
% collect positive examples in parallel batches
for i = 1:batchsize:numpos
  % do batches of detections in parallel
  thisbatchsize = batchsize - max(0, (i+batchsize-1) - numpos);
  % data for batch
  data = {};
  parfor k = 1:thisbatchsize
    j = i+k-1;
    fprintf('%s %s: iter %d/%d: latent positive: %d/%d', procid(), name, t, iter, j, numpos);
    bbox = [pos(j).x1 pos(j).y1 pos(j).x2 pos(j).y2];
    % skip small examples
    if (bbox(3)-bbox(1)+1)*(bbox(4)-bbox(2)+1) < minsize
      data{k} = [];
      fprintf(' (too small)\n');
      continue;
    end
    % get example
    im = color(imreadx(pos(j)));
    [im, bbox] = croppos(im, bbox);
    pyra = featpyramid(im, model);
    [det, bs, info] = gdetect(pyra, model, 0, bbox, overlap);
    data{k}.bs = bs;
    data{k}.pyra = pyra;
    data{k}.info = info;
    if ~isempty(bs)
      fprintf(' (comp %d  score %.3f)\n', bs(1,end-1), bs(1,end));
    else
      fprintf(' (no overlap)\n');
    end
  end
  % write feature vectors sequentially 
  for k = 1:thisbatchsize
    if isempty(data{k})
      continue;
    end
    j = i+k-1;
    bs = gdetectwrite(data{k}.pyra, model, data{k}.bs, data{k}.info, 1, j);
    if ~isempty(bs)
      fusage = fusage + getfusage(bs);
      num = num+1;
      scores(num) = bs(1,end);
    end
  end
end


% get hard negative examples
function [num, j, fusage, scores, complete] ...
  = neghard(name, t, negiter, model, neg, maxsize, negpos, maxnum)
model.interval = 4;
fusage = zeros(model.numfilters, 1);
numneg = length(neg);
num = 0;
scores = [];
complete = 1;
batchsize = max(1, try_get_matlabpool_size());
inds = circshift(1:numneg, [0 -negpos]);
for i = 1:batchsize:numneg
  % do batches of detections in parallel
  thisbatchsize = batchsize - max(0, (i+batchsize-1) - numneg);
  data = {};
  parfor k = 1:thisbatchsize
    j = inds(i+k-1);
    fprintf('%s %s: iter %d/%d: hard negatives: %d/%d (%d)\n', procid(), name, t, negiter, i+k-1, numneg, j);
    im = color(imreadx(neg(j)));
    pyra = featpyramid(im, model);
    [dets, bs, info] = gdetect(pyra, model, -1.002);
    data{k}.bs = bs;
    data{k}.pyra = pyra;
    data{k}.info = info;
  end
  % write feature vectors sequentially 
  for k = 1:thisbatchsize
    j = inds(i+k-1);
    bs = gdetectwrite(data{k}.pyra, model, data{k}.bs, data{k}.info, ...
                      -1, j, maxsize, maxnum-num);
    if ~isempty(bs)
      fusage = fusage + getfusage(bs);
      scores = [scores; bs(:,end)];
    end
    num = num+size(bs, 1);
    byte_size = fv_cache('byte_size');
    if byte_size >= maxsize || num >= maxnum
      fprintf('reached memory limit\n');
      complete = 0;
      break;
    end
  end
  if complete == 0
    break;
  end
end


% get random negative examples
function num = negrandom(name, t, model, c, neg, maxnum)
numneg = length(neg);
rndneg = floor(maxnum/numneg);
fi = model.symbols(model.rules{model.start}.rhs).filter;
rsize = model.filters(fi).size;
width1 = ceil(rsize(2)/2);
width2 = floor(rsize(2)/2);
fbl = model.filters(fi).blocklabel;
obl = model.rules{model.start}.offset.blocklabel;
num = 0;
for i = 1:numneg
  fprintf('%s %s: iter %d: random negatives: %d/%d\n', procid(), name, t, i, numneg);
  im = imreadx(neg(i));
  feat = features(double(im), model.sbin);  
  if size(feat,2) > rsize(2) && size(feat,1) > rsize(1)
    for j = 1:rndneg
      x = random('unid', size(feat,2)-rsize(2)+1);
      y = random('unid', size(feat,1)-rsize(1)+1);
      f = feat(y:y+rsize(1)-1, x:x+rsize(2)-1,:);
      dim = numel(f) + 3;
      key = [-1 (i-1)*rndneg+j 0 0 0];
      fv = [obl; 1; fbl; f(:)];
      fv_cache('add', int32(key), 2, dim, single(fv)); 
    end
    num = num+rndneg;
  end
end


% collect filter usage statistics
function u = getfusage(boxes)
numfilters = floor(size(boxes, 2)/4);
u = zeros(numfilters, 1);
nboxes = size(boxes,1);
for i = 1:numfilters
  x1 = boxes(:,1+(i-1)*4);
  y1 = boxes(:,2+(i-1)*4);
  x2 = boxes(:,3+(i-1)*4);
  y2 = boxes(:,4+(i-1)*4);
  ndel = sum((x1 == 0) .* (x2 == 0) .* (y1 == 0) .* (y2 == 0));
  u(i) = nboxes - ndel;
end

function s = close_parallel_pool()
try
  s = matlabpool('size');
  if s > 0
    matlabpool('close', 'force');
  end
catch
  s = 0;
end

function reopen_parallel_pool(s)
if s > 0
  while true
    try
      matlabpool('open', s);
      break;
    catch
      fprintf('Ugg! Something bad happened. Trying again in 10 seconds...\n');
      pause(10);
    end
  end
end

function s = try_get_matlabpool_size()
try
  s = matlabpool('size');
catch
  s = 0;
end
