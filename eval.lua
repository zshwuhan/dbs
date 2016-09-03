require 'torch'
require 'nn'
require 'nngraph'
require 'debug'
-- exotics
require 'loadcaffe'
-- local imports
utils = require 'misc.utils'
require 'misc.DataLoader'
require 'misc.DataLoaderRaw'
require 'misc.LanguageModel'
net_utils = require 'misc.net_utils'
beam_utils = require 'dbs.beam_utils'
-- div_utils = require 'dbs.div_utils'
-- vis_utils = require 'misc.vis_utils'

local debug = require 'debug'

-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train an Image Captioning model')
cmd:text()
cmd:text('Options')

-- Input paths
cmd:option('-model','','path to model to evaluate')

-- Basic options
cmd:option('-batch_size', 1, 'if > 0 then overrule, otherwise load from checkpoint.')
cmd:option('-num_images', 1, 'how many images to use when periodically evaluating the loss? (-1 = all)')
-- cmd:option('-language_eval', 0, 'Evaluate language as well (1 = yes, 0 = no)? BLEU/CIDEr/METEOR/ROUGE_L? requires coco-caption code from Github.')
cmd:option('-dump_images', 1, 'Dump images into vis/imgs folder for vis? (1=yes,0=no)')
cmd:option('-dump_json', 1, 'Dump json with predictions into vis folder? (1=yes,0=no)')
-- cmd:option('-dump_path', 0, 'Write image paths along with predictions into vis json? (1=yes,0=no)')

-- Sampling options
-- cmd:option('-sample_max', 1, '1 = sample argmax words. 0 = sample from distributions.')
cmd:option('-B', 2, 'used when sample_max = 1, indicates number of beams in beam search. Usually 2 or 3 works well. More is not better. Set this to 1 for faster runtime but a bit worse performance.')
cmd:option('-M',2,'number of diverse groups')
cmd:option('-lambda', 0.5, 'diversity penalty')
-- cmd:option('-divmode', 0, '1 to turn on cumulative_diversity')
-- cmd:option('-temperature', 1.0, 'temperature when sampling from distributions (i.e. when sample_max = 0). Lower = "safer" predictions.')
cmd:option('-primetext', "", 'used as a prompt to "seed" the state of the LSTM using a given sequence, before we sample.')
-- For evaluation on a folder of images:
cmd:option('-image_folder', '', 'If this is nonempty then will predict on the images in this folder path')
cmd:option('-image_root', '', 'In case the image paths have to be preprended with a root path to an image folder')
-- For evaluation on MSCOCO images from some split:
cmd:option('-input_h5','','path to the h5file containing the preprocessed dataset. empty = fetch from model checkpoint.')
cmd:option('-input_json','','path to the json file containing additional info and vocab. empty = fetch from model checkpoint.')
 cmd:option('-split', 'test', 'if running on MSCOCO images, which split to use: val|test|train')
 cmd:option('-coco_json', '', 'if nonempty then use this file in DataLoaderRaw (see docs there). Used only in MSCOCO test evaluation, where we have a specific json file of only test set images.')

-- misc
cmd:option('-backend', 'cudnn', 'nn|cudnn')
cmd:option('-id', 'evalscript', 'an id identifying this run/job. used only if language_eval = 1 for appending to intermediate files')
cmd:option('-seed', 123, 'random number generator seed to use')
cmd:option('-gpuid', -1, 'which gpu to use. -1 = use CPU')
-- cmd:option('-div_vis_dir', '', 'store information for the div rnn vis in this directory; it should already exist')
-- cmd:option('-baseline',-1,'implements the stanford baseline if >=0 with strength equal to the set value. -1 implements conventional DBS -- use M = 1 and opt.baseline >0 to run stanford baseline')
cmd:text()

-------------------------------------------------------------------------------
-- Basic Torch initializations
-------------------------------------------------------------------------------
local opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
torch.setdefaulttensortype('torch.FloatTensor') -- for CPU

if opt.gpuid >= 0 then
  require 'cutorch'
  require 'cunn'
  if opt.backend == 'cudnn' then require 'cudnn' end
  cutorch.manualSeed(opt.seed)
  cutorch.setDevice(opt.gpuid + 1) -- note +1 because lua is 1-indexed
end

-------------------------------------------------------------------------------
-- invert vocab
-------------------------------------------------------------------------------
function table_invert(t)
    local s ={}
    for k,v in pairs(t) do
        s[v] = k
    end
    return s
end 

-------------------------------------------------------------------------------
-- Load the model checkpoint to evaluate
-------------------------------------------------------------------------------
assert(string.len(opt.model) > 0, 'must provide a model')
print(opt.model)
local checkpoint = torch.load(opt.model)
-- override and collect parameters
if string.len(opt.input_h5) == 0 then opt.input_h5 = checkpoint.opt.input_h5 end
if string.len(opt.input_json) == 0 then opt.input_json = checkpoint.opt.input_json end
if opt.batch_size == 0 then opt.batch_size = checkpoint.opt.batch_size end
local fetch = {'rnn_size', 'input_encoding_size', 'drop_prob_lm', 'cnn_proto', 'cnn_model', 'seq_per_img'}
for k,v in pairs(fetch) do 
  opt[v] = checkpoint.opt[v] -- copy over options from model
end
local vocab = checkpoint.vocab -- ix -> word mapping
local inv_vocab = table_invert(checkpoint.vocab)
-------------------------------------------------------------------------------
-- Create the Data Loader instance
-------------------------------------------------------------------------------
local loader
if string.len(opt.image_folder) == 0 then
  loader = DataLoader{h5_file = opt.input_h5, json_file = opt.input_json}
else
  loader = DataLoaderRaw{folder_path = opt.image_folder, coco_json = opt.coco_json}
end

-------------------------------------------------------------------------------
-- Load the networks from model checkpoint
-------------------------------------------------------------------------------
local protos = checkpoint.protos
protos.expander = nn.FeatExpander(opt.seq_per_img)
protos.crit = nn.LanguageModelCriterion()
protos.lm:createClones() -- reconstruct clones inside the language model
if opt.gpuid >= 0 then for k,v in pairs(protos) do v:cuda() end end


-------------------------------------------------------------------------------
-- Evaluation fun(ction)
-------------------------------------------------------------------------------
local function eval_split(split, evalopt)
  local verbose = utils.getopt(evalopt, 'verbose', true)
  local num_images = utils.getopt(evalopt, 'num_images', true)

  protos.cnn:evaluate()
  protos.lm:evaluate()
  loader:resetIterator(split) -- rewind iteator back to first datapoint in the split
  local n = 0
  local loss_sum = 0
  local loss_evals = 0
  local final_beams = {}
  while true do

    -- fetch a batch of data
    local data = loader:getBatch{batch_size = opt.batch_size, split = split, seq_per_img = opt.seq_per_img}
    data.images = net_utils.prepro(data.images, false, opt.gpuid >= 0) -- preprocess in place, and don't augment
    n = n + data.images:size(1)
    -- forward the model to get loss
    local feats = protos.cnn:forward(data.images)

    -- evaluate loss if we have the labels
    local loss = 0
    if data.labels then
      local expanded_feats = protos.expander:forward(feats)
      local logprobs = protos.lm:forward{expanded_feats, data.labels}
      loss = protos.crit:forward(logprobs, data.labels)
      loss_sum = loss_sum + loss
      loss_evals = loss_evals + 1
    end

    local function gen_logprobs(word_ix, state)
        local embedding = protos.lm.lookup_table:forward(word_ix)
        local inputs = {embedding, unpack(state)}
        return protos.lm.core:forward(inputs)
    end

    -- forward the model to also get generated samples for each image
    local sample_opts = {
        T = protos.lm.seq_length,
        B = opt.B,
        M = opt.M,
        lambda = opt.lambda,
        temperature = opt.temperature,
        -- size of a state
        state_size = protos.lm.num_layers * 2,
        rnn_size = protos.lm.rnn_size,
        end_token = protos.lm.vocab_size + 1,
        gen_logprobs = gen_logprobs,
        use_gpu = (opt.gpuid >= 0),
        divmode = opt.divmode,
        primetext = opt.primetext,
		baseline = opt.baseline
    }
    
    -- function to preprocess prime text if provided
    local function preproc_prime(prime)
        return prime:lower():gsub("%p", "")
    end

    -- prime lstm with image features embedded to vocab space
    local function prime_model() 
        -- forward 0 state and image embedding
        state = {}
        for i = 1,sample_opts.state_size do
            state[i] = torch.zeros(sample_opts.rnn_size)
            if sample_opts.use_gpu then
                state[i] = state[i]:cuda()
            end
        end
        local states_and_logprobs = protos.lm.core:forward({feats, unpack(state)})
        -- forward start token
        local start_token = torch.LongTensor(1):fill(protos.lm.vocab_size+1)
        if sample_opts.use_gpu then
            start_token = start_token:cuda()
        end
        for i = 1,sample_opts.state_size do
            state[i] = states_and_logprobs[i]:clone()
        end
        states_and_logprobs = gen_logprobs(start_token, state)
        -- get initial state for beam search
        local logprobs = states_and_logprobs[#states_and_logprobs]
        for i = 1,sample_opts.state_size do
            state[i] = states_and_logprobs[i]:clone()
        end
       
        -- input the prime text
        for word in preproc_prime(opt.primetext):gmatch'%w+' do
            ix = inv_vocab[word]
            if ix == nil then
                -- UNK
                ix = protos.lm.vocab_size
            end
            local ix_word = torch.LongTensor(1):fill(ix)
            if sample_opts.use_gpu then
                ix_word = ix_word:cuda()
            end
            states_and_logprobs = gen_logprobs(ix_word, state)
            for i = 1, sample_opts.state_size do
                state[i] = states_and_logprobs[i]:clone()
                logprobs = states_and_logprobs[#states_and_logprobs]
            end
        end
        
        local init = {}
        init[1] = state
        init[2] = logprobs
        return init
    end

    local init = prime_model()
    final_beams[n] = {}
    temp_name = string.split(data.infos[1].file_path,'/')
    final_beams[n]['image_id'] = temp_name[#temp_name]
    local start_time = os.clock()
    final_beams[n]['caption'] = beam_utils.beam_search(init, sample_opts)
    local end_time = os.clock()
    print("time taken is:", end_time-start_time,"seconds")

	print('done with image: ' .. n)

    if data.bounds.wrapped then break end -- the split ran out of data, lets break out
    if num_images >= 0 and n >= num_images then break end -- we've used enough images

	end

	return final_beams
end

-- function to print the beams and dump it to a json
-- the json is table containing the image name as the key
local function print_and_dump_beam(opt,beam_table)
	print('\nOUTPUT:')
	print('----------------------------------------------------')
  local function compare_beam(a,b) return a.logp > b.logp end
	json_table = {}
	bdash = opt.B / opt.M
  for im_n = 1,#beam_table do
		json_table[im_n] = {}
		json_table[im_n]['image_id'] = beam_table[im_n]['image_id']
		json_table[im_n]['captions'] = {}
		for i = 1,opt.M do
			for j = 1,bdash do
				current_beam_string = table.concat(net_utils.decode_sequence(vocab, torch.reshape(beam_table[im_n]['caption'][i][j].seq, beam_table[im_n]['caption'][i][j].seq:size(1), 1)))
				print('beam ' .. (i-1)*bdash+j ..' diverse group: '..i)
				print(string.format('%s',current_beam_string))	
				print('----------------------------------------------------')
				json_table[im_n]['captions'][(i-1)*bdash+j] = {}
			
                json_table[im_n]['captions'][(i-1)*bdash+j]['logp'] = beam_table[im_n]['caption'][i][j].unaug_logp
				json_table[im_n]['captions'][(i-1)*bdash+j]['sentence'] = current_beam_string
			end
		end
       
        -- sort the candidates by logprobability
        -- uncomment below line if the actual order is needed
		table.sort(json_table[im_n]['captions'],compare_beam)
	end
	if opt.dump_json == 1 then
		-- dump the json
		utils.write_json('amt_all_images_0.4.json', json_table)
	end
	return json_table
end

-- print and dump the table here
local beam_table  = eval_split(opt.split, {num_images = opt.num_images})
print_and_dump_beam(opt,beam_table)

