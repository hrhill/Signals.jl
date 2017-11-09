"""
    s = buffer(input; buf_size = Inf, timespan = 1, type_stable = false)
creates a signal who buffers updates to signal `input` until maximum size of `buf_size`
or until `timespan` seconds have passed. The signal value is the last
full buffer emitted or an empty vector if the buffer have never
been filled before.

buffer type will be `Any` unless `type_stable` is set to `true`, then it will be set
to the value of the first encountered item
"""

function buffer(input; buf_size = Inf, timespan = 1, type_stable = false)
    _buf = type_stable ? Vector{typeof(f(pull!.(args)...))} : Vector{Any}[]
    sbuf = foldp(push!,_buf,input)
    cond = Signal(sbuf;state = time()) do in,state
        last_update = state.x
        (time() - last_update > timespan) || (length(in) >= buf_size)
    end
    when(cond,sbuf) do buf
        cond.state.x = time()
        frame = copy(buf)
        empty!(_buf)
        frame
    end
end
export buffer

"""
    debounce(f,args...;delay = 1 , v0 = nothing)
Creates a `Signal` whos action `f(args...)` will be called only after `delay` seconds have passed since the last time
its `args` were updated. only works in push based paradigm. if v0 is not specified
then the initial value is `f(args...)`
"""
function debounce(f,args...;delay = 1 , v0 = nothing)
    ref_timer = Ref(Timer(identity,0))
    f_args = PullAction(f,args)
    debounced_signal = Signal(v0 == nothing ? f_args() : v0)
    Signal(args...) do args
        finalize(ref_timer.x)
        ref_timer.x = Timer(t->debounced_signal(f_args()),delay)
    end
    debounced_signal
end
export debounce

abstract type Throttle <: PullType end
"""
    throttle(f::Function,args...;maxfps = 0.03)
Creates a throttled `Signal` whos action `f(args...)` will be called only
if `1/maxfps` time has passed since the last time it updated. The resulting `Signal`
will be updated maximum of `maxfps` times per second
"""
function throttle(f::Function,args... ; maxfps = 30)
    sd = SignalData(f(pull_args(args)...))
    pa = PullAction(f,args,Throttle)
    state = Ref((1/maxfps,time()))
    Signal(sd,pa,state)
end
export throttle

(pa::PullAction{Throttle,A})(s) where A = begin
    (dt,last_update) = s.state.x
    args = pull_args(pa)
    if !valid(s)
        if time() - last_update < dt
            validate(s)
        else
            s.state.x = (dt,time())
            store!(s,pa.f(args...))
        end
    end
    value(s)
end

activate_timer(s,dt,duration) = begin
    signalref = WeakRef(Ref(s))
    start_time = time()
    t = Timer(dt,dt) do t
        time_passed = time() - start_time
        if time_passed > duration || signalref.value == nothing
            finalize(t)
        else
            signalref.value.x(time())
        end
        nothing
    end
    t
end

"""
    s = every(dt;duration = Inf)

A signal that updates every `dt` seconds to the current timestamp, for `duration` seconds
"""
function every(dt;duration  = Inf)
    res = Signal(time())
    activate_timer(res,dt,duration)
    res
end
export every

"""
    s = fps(dt;duration = Inf)

A signal that updates `fps` times a second to the current timestamp, for `duration` seconds
"""
function fps(freq;duration  = Inf)
    every(1/freq; duration = duration)
end
export fps

"""
    s = fpswhen(switch::Signal,dt;duration = Inf)

A signal that updates 'fps' times a second to the current timestamp, for `duration` seconds
if and only if the value of `switch` is `true`.
"""
function fpswhen(switch::Signal,freq; duration = Inf)
    res = Signal(time())
    timer = Timer(0)
    Signal(droprepeats(switch)) do sw
        if sw == true
            timer = activate_timer(res,1/freq,duration)
        else
            finalize(timer)
        end
    end
    res
end
export fpswhen

"""
     s = for_signal(f::Function,args...;range = 1:1, fps = 1)
creates a `Signal` that updates to `f(args...,i) for i in range` every 1/fps seconds.
`Signal` input arguments to `f` get replaced by their value.
 The loop starts whenever one of the agruments or when `range` itself updates. If the
previous for loop did not complete it gets cancelled

"""
function for_signal(f::Function,args...;range = 1:1,fps = 1)
    res = Signal(start(valiue(range)))
    signalref = WeakRef(Ref(res))
    timer = Timer(0)
    Signal(args...,range) do args,iter
        finalize(timer)
        state = Ref(start(iter))
        timer = Timer(dt,dt) do t
            if done(iter,state.x)
                finalize(t)
            else
                signalref.value.x(state.x)
                (~,state.x ) = next(iter,state.x)
            end
            nothing
        end
    end
    res
end
export for_signal


nothing