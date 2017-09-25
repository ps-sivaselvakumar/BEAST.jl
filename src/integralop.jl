using CUDAdrv, CUDAnative
abstract type IntegralOperator <: Operator end

export quadrule, elements

"""
    quadrule(operator,test_refspace,trial_refspace,p,test_element,q_trial_element, qd)

Returns an object that contains all the dynamic (runtime) information that
defines the integration strategy that will be used by `momintegrals!` to compute
the interactions between the local test/trial functions defined on the specified
geometric elements. The indices `p` and `q` refer to the position of the test
and trial elements as encountered during iteration over the output of
`geometry`.

The last argument `qd` provides access to all precomputed data required for
quadrature. For example it might be desirable to precompute all the quadrature
points for all possible numerical quadrature schemes that can potentially be
required during matrix assembly. This makes sense, since the number of point is
order N (where N is the number of faces) but these points will appear in N^2
computations. Precomputation requires some extra memory but can save a lot on
computation time.
"""
function quadrule end


"""
  elements(geo)

Create an iterable collection of the elements stored in `geo`. The order in which
this collection produces the elements determines the index used for lookup in the
data structures returned by `assemblydata` and `quaddata`.
"""
#elements(geo) = [simplex(vertices(geo,cl)) for cl in cells(geo)]
elements(geo) = [chart(geo,cl) for cl in cells(geo)]

elements(sp::Space) = elements(geometry(sp))

"""
    assemblechunk!(biop::IntegralOperator, tfs, bfs, store)

Computes the matrix of operator biop wrt the finite element spaces tfs and bfs
"""
function assemblechunk!(biop::IntegralOperator, tfs::Space, bfs::Space, store)

    test_elements, tad = assemblydata(tfs)
    bsis_elements, bad = assemblydata(bfs)

    tshapes = refspace(tfs); num_tshapes = numfunctions(tshapes)
    bshapes = refspace(bfs); num_bshapes = numfunctions(bshapes)

    qd = quaddata(biop, tshapes, bshapes, test_elements, bsis_elements)
    T = promote_type(scalartype(biop), scalartype(tfs), scalartype(bfs))
    zlocal = zeros(T, num_tshapes, num_bshapes)

    print("dots out of 10: ")
    todo, done, pctg = length(test_elements), 0, 0
    for p in eachindex(test_elements)
        tcell = test_elements[p]
        for q in eachindex(bsis_elements)
            bcell = bsis_elements[q]

            fill!(zlocal, 0)
            strat = quadrule(biop, tshapes, bshapes, p, tcell, q, bcell, qd)
            momintegrals!(biop, tshapes, bshapes, tcell, bcell, zlocal, strat)

            for j in 1 : num_bshapes, i in 1 : num_tshapes
                z = zlocal[i,j]
                for (n,b) in bad[q,j], (m,a) in tad[p,i]
                    store(a*z*b, m, n)
        end end end

        done += 1
        new_pctg = round(Int, done / todo * 100)
        (new_pctg > pctg + 9) && (print("."); pctg = new_pctg)
    end
    print(" done. ")
end








immutable DoubleQuadStrategy{P,Q}
  outer_quad_points::P
  inner_quad_points::Q
end

#Kernel
function kernel(jx, jy, j, len_jx, len_jy, tgeos, bgeos, kernelvals, len_tgeos, len_bgeos, size_tgeos, size_bgeos, γ)
    
    m = (blockIdx().x-1) * blockDim().x + threadIdx().x
	n = (blockIdx().y-1) * blockDim().y + threadIdx().y
    jID = n + len_jy * (m - 1)
    kernelID = n + size_bgeos * (m - 1)

    a = 1 + (m - 1) * 3  
    b = 2 + (m - 1) * 3  
    c = 3 + (m - 1) * 3

    x = 1 + (n - 1) * 3  
    y = 2 + (n - 1) * 3  
    z = 3 + (n - 1) * 3  

    if m <= len_jx 
        if n <= len_jy       
            j[jID] = jx[m] * jy[n]
        end
    end

    if a <= len_tgeos 
        if x <= len_bgeos 
            R = sqrt((tgeos[a] - bgeos[x])^2 + (tgeos[b] - bgeos[y])^2 + (tgeos[c] - bgeos[z])^2)
            γR = -(R*γ)
            RealPart = real(γR)
            ImgPart = imag(γR)
            numerator = (exp(RealPart))*(CUDAnative.cos(ImgPart) + im*CUDAnative.sin(ImgPart))
            kernelvals[kernelID] = numerator/(4*pi*R)
       end
    end 

    return nothing
end

"""
    regularcellcellinteractions!(biop, tshs, bshs, tcell, bcell, interactions, strat)

Function for the computation of moment integrals using simple double quadrature.
"""
function momintegrals!(biop, tshs, bshs, tcell, bcell, z, strat::DoubleQuadStrategy)

    # memory allocation here is a result from the type instability on strat
    # which is on purpose, i.e. the momintegrals! method is chosen based
    # on dynamic polymorphism.
    womps = strat.outer_quad_points
    wimps = strat.inner_quad_points

    M, N = size(z)
    γ = 0.0 + 1.0im
    α = 1.0 + 1.0im
    β = 1.0 + 1.0im

	#Device Initialisation
    dev = CuDevice(0)
    ctx = CuContext(dev)
    
    #Making an array
    jx = [womp.weight for womp in womps]
    jy = [wimp.weight for wimp in wimps]
    tgeos = [womp.point.cart[i] for womp in womps, i = 1:3]
    bgeos = [wimp.point.cart[i] for wimp in wimps, i = 1:3]
    t_tgeos = transpose(tgeos)
    t_bgeos = transpose(bgeos)
    tvals = [womp.value for womp in womps]
    bvals = [wimp.value for wimp in wimps]
    gvalue = [womp.value[i][2] for womp in womps, i = 1:3]
    g = gvalue[1]
    fvalue = [wimp.value[i][2] for wimp in wimps, i = 1:3]    
    f = fvalue[1]
    ntgeos = [normal(womp.point) for womp in womps] 
    nx = ntgeos[1]
    nbgeos = [normal(wimp.point) for wimp in wimps] 
    ny = nbgeos[1]    
    αdgf = α*dot(nx, ny)*g*f   
    
    #Determining the length of the arrays
    len_jx = length(jx)  
    len_jy = length(jy)
    size_tgeos = size(t_tgeos,2)
    size_bgeos = size(t_bgeos,2)  
    len_tgeos = length(t_tgeos)
    len_bgeos = length(t_bgeos)
   
    #From Host to Device
    d_jx = CuArray(jx)
    d_jy = CuArray(jy)
    d_j = CuArray{Float64}(len_jx * len_jy) 
    d_tgeos = CuArray{Float64,2}(size(t_tgeos))
    copy!(d_tgeos, t_tgeos)
    d_bgeos = CuArray{Float64,2}(size(t_bgeos))
    copy!(d_bgeos, t_bgeos)
    d_kernelvals = CuArray{Complex{Float64},1}(size_tgeos * size_bgeos)


    #Kernel launch
    @cuda ((500,500,1),(1,1,1)) kernel(d_jx, d_jy, d_j, len_jx, len_jy, d_tgeos, d_bgeos, d_kernelvals, len_tgeos, len_bgeos, size_tgeos, size_bgeos, γ)

    #Copying back from the device 
    j = Array(d_j)
    kernelvals = Array{Complex{Float64},1}(d_kernelvals)
    
    for i in 1 : length(j)    
        for m in 1 : M
            tval = tvals[m]
            for n in 1 : N
                bval = bvals[n]                 
                
                g, curlg = tval
                f, curlf = bval                
                igd = αdgf + β*dot(curlg[1], curlf[1])
                z[m,n] += j[i] * kernelvals[i] * igd

            end
        end
    end
     
    synchronize()
    destroy!(ctx) 
    return z
end


abstract type SingularityExtractionStrategy end
regularpart_quadrule(qr::SingularityExtractionStrategy) = qr.regularpart_quadrule

function momintegrals!(op, g, f, t, s, z, strat::SingularityExtractionStrategy)

    womps = strat.outer_quad_points

    sop = singularpart(op)
    rop = regularpart(op)

    # compute the regular part
    rstrat = regularpart_quadrule(strat)
    momintegrals!(rop, g, f, t, s, z, rstrat)

    for p in 1 : length(womps)
        x = womps[p].point
        dx = womps[p].weight

        innerintegrals!(sop, x, g, f, t, s, z, strat, dx)
    end # next quadrature point

end


type QuadData{WPV1,WPV2}
  tpoints::Matrix{Vector{WPV1}}
  bpoints::Matrix{Vector{WPV2}}
end
