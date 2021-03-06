type PlaneWaveMWTD{T,F,P} <: TDFunctional{T}
  direction::P
  polarisation::P
  speedoflight::T
  amplitude::F
end

# """
#     speedoflight(excitation)
#
# Returns the speed of light of the medium the excitation is defined in.
# """
# speedoflight(exc::PlaneWaveMWTD) = exc.speedoflight



function planewave(polarisation,direction,amplitude,speedoflight)
    PlaneWaveMWTD(direction,polarisation,speedoflight,amplitude)
end

*(a, pw::PlaneWaveMWTD) = PlaneWaveMWTD(
    pw.direction,
    a * pw.polarisation,
    pw.speedoflight,
    pw.amplitude
)

cross(k, pw::PlaneWaveMWTD) = PlaneWaveMWTD(
    pw.direction,
    k × pw.polarisation,
    pw.speedoflight,
    pw.amplitude
)

@compat function (f::PlaneWaveMWTD)(r,t)
    #dr = zero(typeof(t))
    t = cartesian(t)[1]
    #dr = zero(eltype(cartesian(r)))
    dr = zero(typeof(t))
    for i in 1 : 3
        dr += r[i]*f.direction[i]
    end
    f.polarisation * f.amplitude(f.speedoflight*t - dr)
end
