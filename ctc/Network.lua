--Handles the interaction of a fixed size deep neural network of 256 input, 27 output
--for speech recognition.
module(...,package.seeall)
require 'cunn'
require 'CTCCriterion'
require 'optim'
require 'rnn'
require 'gnuplot'

local Network = {}

local logger = optim.Logger('train.log')
logger:setNames{'loss'}
logger:style{'-'}
--Returns a new network based on the speech recognition stack.
function Network.createSpeechNetwork()
    local net = nn.Sequential()
    torch.manualSeed(12345)
    net:add(nn.Sequencer(nn.TemporalConvolution(251,251,5,1)))
    net:add(nn.Sequencer(nn.ReLU()))
    net:add(nn.Sequencer(nn.TemporalMaxPooling(2,2)))
    net:add(nn.Sequencer(nn.TemporalConvolution(251,251,5,1)))
    net:add(nn.Sequencer(nn.ReLU()))
    net:add(nn.Sequencer(nn.TemporalConvolution(251,251,5,1)))
    net:add(nn.Sequencer(nn.ReLU()))
    net:add(nn.Sequencer(nn.BatchNormalization(251)))
    net:add(nn.Sequencer(nn.Linear(251,251)))
    net:add(nn.Sequencer(nn.ReLU()))
    net:add(nn.BiSequencer(nn.FastLSTM(251,40),nn.FastLSTM(251,40)))
    net:add(nn.Sequencer(nn.BatchNormalization(40*2)))
    net:add(nn.BiSequencer(nn.FastLSTM(40*2,30),nn.FastLSTM(40*2,30)))
    net:add(nn.Sequencer(nn.BatchNormalization(30*2)))
    net:add(nn.BiSequencer(nn.FastLSTM(30*2,20),nn.FastLSTM(30*2,20)))
    net:add(nn.Sequencer(nn.BatchNormalization(20*2)))
    net:add(nn.Sequencer(nn.Linear(20*2,27)))
    net:add(nn.Sequencer(nn.SoftMax()))
    return net
end

--Returns the largest tensor size and all sizes in a table of tensors
function findMaxSize(tensors)
    local maxSize = 0
    local allSizes = {}
    for i=1,#tensors do
        local tensorSize = tensors[i]:size(1)
        if(tensorSize > maxSize) then maxSize = tensorSize end
        table.insert(allSizes,tensorSize)
    end
    return allSizes,maxSize
end

--Pads a dataset with 0's so all tensors are off the same size.
function padDataset(totalInput)
    local allSizes,maxSize = findMaxSize(totalInput)
    local emptyMax = {}
    for i=1,totalInput[1]:size(2) do
        table.insert(emptyMax,0)
    end
    for i=1,#totalInput do
        local input = torch.totable(totalInput[i])
        while(#input < maxSize) do
            table.insert(input,emptyMax)
        end
        totalInput[i] = torch.Tensor(input)
    end
    return totalInput
end

function createDataSet(inputJson, labelJson, batchSize)
    local dataset = {}
    for t = 1,#inputJson,batchSize do
        local inputs = {}
        local targets = {}
        for i = t,math.min(t+batchSize-1,#inputJson) do
            table.insert(inputs, inputJson[i])
            table.insert(targets, labelJson[i])
        end
        table.insert(dataset,{padDataset(inputs),targets})
    end
    local pointer = 1
    function dataset:size() return #dataset end
    function dataset:nextData()
        local sample = dataset[pointer]
        pointer = pointer + 1
        if(pointer > dataset:size()) then pointer = 1 end
        return sample[1],sample[2]
    end
    return dataset
end

--Returns a prediction of the input net and input tensors.
function Network.predict(net,inputTensors)
    local prediction = net:forward(inputTensors)
    return prediction
end

--Trains the network using SGD and the defined feval.
--Uses warp-ctc cost evaluation.
function Network.trainNetwork(net, inputTensors, labels, batchSize, epochs)
    local ctcCriterion = CTCCriterion()
    local x, gradParameters = net:getParameters()
    local dataset = createDataSet(inputTensors, labels, batchSize)
    local function feval(params)
        local inputs,targets = dataset:nextData()
        gradParameters:zero()
        local predictions = net:forward(inputs)
        local loss = ctcCriterion:forward(predictions,targets)
        net:zeroGradParameters()
        local gradOutput = ctcCriterion:backward(predictions,targets)
        net:backward(inputs,gradOutput)
        return loss, gradParameters
    end

    local sgd_params = {
        learningRate = 0.0001,
        learningRateDecay = 1e-9,
        weightDecay = 0,
        momentum = 0.9
    }
    local currentLoss
    local i = 0
    while i < epochs  do
        currentLoss = 0
        i = i + 1
        local _,fs = optim.sgd(feval,x,sgd_params)
        currentLoss = currentLoss + fs[1]
        logger:add{currentLoss}
        print("Loss: ",currentLoss, " iteration: ", i)
    end
    logger:plot()
end

return Network