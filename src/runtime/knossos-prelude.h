// Defines everything in Knossos.ks

namespace ks {
// ===============================  Test edef  ========================
// These only exist so that we can test edef functionality.
// We should probably come up with a better story for the
// tests but at the time of writing I didn't want to hold back
// edef support any longer.
double edef_example(double x) { return x; }
double fwd$edef_example(double x, double dx) { return dx; }
double rev$edef_example(double x, double ddr) { return ddr; }

double dotv(vec<double> const& a, vec<double> const& b)
{
	return dot(a,b);
}

vec<double> 
mul$Mat$Vec(vec<vec<double>> const& M, vec<double> const& v)
{
	int r = size(M);
	vec<double> ret(r);
	for(int i = 0; i < r; ++i)
		ret[i] = dot(M[i], v);
	return ret;
}

tuple<vec<vec<double>>,vec<double>> 
rev$mul$Mat$Vec(std::tuple<vec<vec<double>>, vec<double>> const& M_v, vec<double> const& dr)
{
        auto [M, v] = M_v;
	int r = size(M);
	int c = size(v);
	vec<vec<double>> retM(r);
	for(int i = 0; i < r; ++i)
		retM[i] = v*dr[i];

	vec<double> retv(c);
	for(int i = 0; i < c; ++i) {
		double retvi = 0;
		for(int j = 0; j < r; ++j)
			retvi += M[j][i] * dr[j];
		retv[i] = retvi;
	}

	return std::make_tuple(retM,retv);
}

size_t imaximum(vec<double> const &v)
{
    KS_ASSERT(size(v) > 0);
    size_t imax = 0;
    double vmax = v[imax];
    for (int i = 1; i < size(v); ++i)
        if (v[i] > vmax)
        {
            vmax = v[i];
            imax = i;
        }
    return imax;
}

double maximum(vec<double> const& v) 
{
    return v[imaximum(v)];
}

double fwd$maximum(vec<double> const& v, vec<double> const& dv) 
{
    std::cerr << "[fwd$maximum untested]";
    size_t i = imaximum(v);
    return dv[i];
}

vec<double> rev$maximum(vec<double> const& v, double dr)
{
    std::cerr << "[rev$maximum untested]";
    size_t i = imaximum(v);
    return deltaVec(size(v), i, dr);
}

double digamma(double x)
{
	throw "digamma unimp!\n";
}

double rev$lgamma(double x, double dr)
{
	throw "rev$gamma unimp!\n";
}
double fwd$lgamma(double x, double dx)
{
  if (dx == 0.0) {
    return 0.0;
  } else {
    throw "fwd$gamma unimp except at dx == 0!\n";
  }
}

double pow$aFloat(double x, double e)
{
    return std::pow(x,e);
}

double fwd$pow$aFloat(double x, double e, double dx, double de)
{
	throw "fwd$pow unimp!\n";
}

tuple<double,double> rev$pow$aFloat(double x, double e, double dr)
{
	throw "rev$pow unimp!\n";
}

tuple<> fwd$gt(double a,double b,double d$a,double d$b)
{
    return tuple<>();
}

tuple<double,double> rev$gt(double a,double b, tuple<> d$r)
{
	throw "rev$gt unimp!\n";
}

}
