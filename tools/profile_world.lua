local World=require('world')
local function report(name,value) print(('METRIC,%s,%.6f'):format(name,value)) end
local function percentile(values,p) table.sort(values);return values[math.max(1,math.ceil(#values*p))] end
function love.load()
  love.window.setMode(64,64,{vsync=0})
  collectgarbage('collect');local memory=collectgarbage('count')
  local w=World.new(1337,tonumber(os.getenv("VIEW_DISTANCE")) or 256,{stage=os.getenv("TERRAIN_STAGE")})
  local start=love.timer.getTime();w:initGraphics(0,0,os.getenv('HEIGHT_FORMAT') or 'r16f')
  report('initial_load_ms',(love.timer.getTime()-start)*1000)
  collectgarbage('collect');report('cache_lua_kib',collectgarbage('count')-memory)
  report('cache_height_payload_kib',w.slots^2*256*(w.generateChunk and 2 or 8)/1024)
  report('cache_surface_payload_kib',w.chunks[1] and w.chunks[1].surface and w.slots^2*512/1024 or 0)
  report('span_cpu_kib',w.chunks[1].spans and w.slots^2*4096/1024 or 0)
  report('span_gpu_kib',w.spanTex0 and w.size^2*16/1024 or 0)
  report('span_cpu_image_kib',w.spanData0 and w.size^2*16/1024 or 0)
  report('height_gpu_kib',w.texture:getWidth()*w.texture:getHeight()*(w.texture:getFormat()=='r16f' and 2 or w.texture:getFormat()=='rg16f' and 4 or w.texture:getFormat()=='rg32f' and 8 or 4)/1024)
  local function generate(i)
    local x,y=i%100-50,math.floor(i/100)-50
    if w.generateChunk then return w:generateChunk(x,y) end
    w.queue={{x=x,y=y}};w.head=1;w.pending=nil;w:step(256)
    return w.chunks[w:slot(x,y)]
  end
  for i=1,500 do generate(i) end
  local times={}
  local ordinaryTimes,complexTimes={},{}
  for i=1,4000 do times[i]=0 end
  collectgarbage('collect');collectgarbage('stop');memory=collectgarbage('count')
  start=love.timer.getTime()
  for i=1,4000 do
    local t=love.timer.getTime();local c=generate(i);times[i]=(love.timer.getTime()-t)*1e6
    local category=c.complex and complexTimes or ordinaryTimes;category[#category+1]=times[i]
  end
  local elapsed=love.timer.getTime()-start
  collectgarbage('restart')
  local function generationBatch() for i=1,4000 do generate(i) end end
  generationBatch();generationBatch()
  collectgarbage('collect');collectgarbage('stop');memory=collectgarbage('count')
  generationBatch();report('generation_gc_kib',collectgarbage('count')-memory);collectgarbage('restart')
  report('chunk_us_median',percentile(times,0.5));report('chunk_us_p99',percentile(times,0.99));report('chunks_per_second',4000/elapsed)
  if #ordinaryTimes>0 then report('ordinary_chunk_us_median',percentile(ordinaryTimes,0.5));report('ordinary_chunk_us_p99',percentile(ordinaryTimes,0.99)) end
  if #complexTimes>0 then report('complex_chunk_us_median',percentile(complexTimes,0.5));report('complex_chunk_us_p99',percentile(complexTimes,0.99)) end
  local chunk=generate(1)
  for i=1,100 do w.upload(chunk) end
  for i=1,1000 do local t=love.timer.getTime();w.upload(chunk);times[i]=(love.timer.getTime()-t)*1e6 end
  for i=1001,#times do times[i]=nil end
  report('upload_us_median',percentile(times,0.5));report('upload_us_p99',percentile(times,0.99))
  -- Queue only: one-chunk diagonal movement, no generation or GC inside measurement.
  w:request(0,0)
  for i=1,1100 do w:request(i*16,i*16) end
  w:request(0,0)
  for i=1,100 do w:request(i*16,i*16) end
  collectgarbage('collect');collectgarbage('stop');memory=collectgarbage('count')
  for i=101,1100 do local t=love.timer.getTime();w:request(i*16,i*16);times[i-100]=(love.timer.getTime()-t)*1e6 end
  collectgarbage('restart')
  local function queueBatch() for i=1,1000 do w:request(i*16,i*16) end end
  queueBatch();queueBatch()
  collectgarbage('collect');collectgarbage('stop');memory=collectgarbage('count')
  queueBatch();report('queue_gc_kib',collectgarbage('count')-memory);collectgarbage('restart')
  report('queue_us_median',percentile(times,0.5));report('queue_us_p99',percentile(times,0.99))
  -- Actual update schedule at 60 Hz, measured separately from rendering.
  w:request(0,0)
  while (w.hasPending and w:hasPending() or not w.hasPending and w.head<=#w.queue) do w:step(256,w.upload) end
  local upload=w.upload;local uploadTime=0
  w.upload=function(c) local t=love.timer.getTime();upload(c);uploadTime=uploadTime+love.timer.getTime()-t end
  local step=w.step;local generationTime=0
  w.step=function(self,...)
    local before=uploadTime;local t=love.timer.getTime();local n=step(self,...)
    generationTime=generationTime+love.timer.getTime()-t-(uploadTime-before);return n
  end
  local frames=18000
  local generationFrames={};local streamFrames={};local maxFrame=0;local total=0
  for i=1,frames do
    local before=generationTime;local t=love.timer.getTime();w:update(i*5/60,i*3/60)
    local dt=love.timer.getTime()-t;maxFrame=math.max(maxFrame,dt);total=total+dt
    streamFrames[i]=dt*1000
    generationFrames[i]=(generationTime-before)*1000
  end
  report('generation_frame_ms_mean',generationTime/frames*1000)
  report('generation_frame_ms_p99',percentile(generationFrames,0.99))
  report('stream_frame_ms_mean',total/frames*1000);report('stream_frame_ms_max',maxFrame*1000)
  report('stream_upload_ms_total',uploadTime*1000)
  report('stream_frame_ms_p99',percentile(streamFrames,0.99))
  if w.terrain and w.terrain.regions then
    local r=w.terrain.regions
    report('macro_build_ms_mean',r.cpuSeconds/math.max(1,r.builds)*1000)
    report('macro_build_ms_max',r.maxBuildSeconds*1000)
    report('macro_cache_kib',r.bytes/1024)
    report('macro_builds',r.builds)
    report('cave_build_ms_mean',(r.caveSeconds or 0)/math.max(1,r.builds)*1000)
    report('cave_build_ms_max',(r.maxCaveSeconds or 0)*1000)
    report('span_overflow_count',w.terrain.spanOverflowCount or 0)
  end
end
function love.run()
  local ok,err=pcall(love.load);if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
