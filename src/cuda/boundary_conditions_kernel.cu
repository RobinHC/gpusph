/*  Copyright 2015 Giuseppe Bilotta, Alexis Herault, Robert A. Dalrymple, Eugenio Rustico, Ciro Del Negro

    Istituto Nazionale di Geofisica e Vulcanologia
        Sezione di Catania, Catania, Italy

    Università di Catania, Catania, Italy

    Johns Hopkins University, Baltimore, MD

    This file is part of GPUSPH.

    GPUSPH is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    GPUSPH is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with GPUSPH.  If not, see <http://www.gnu.org/licenses/>.
*/

/* Device functions and constants pertaining open boundaries */

#ifndef _BOUNDS_KERNEL_
#define _BOUNDS_KERNEL_

#include "particledefine.h"

/*!
 * \namespace cubounds
 * \brief Contains all device functions/kernels/constants related to open boundaries and domain geometry.
 *
 * The namespace contains the device side of boundary handling
 *	- domain size, origin and cell grid properties and related functions
 *	- open boundaries properties and related functions
 */
namespace cubounds {

using namespace cuneibs;
using namespace cuphys;
using namespace cusph;

/// \name Device constants
/// @{

/// Number of open boundaries (both inlets and outlets)
__constant__ uint d_numOpenBoundaries;

// host-computed id offset used for id generation
__constant__ uint	d_newIDsOffset;

/// @}

/** \name Device functions
 *  @{ */

/*!
 * Create a new particle, cloning an existing particle
 * This returns the index of the generated particle, initializing new_info
 * for a FLUID particle of the same fluid as the generator, no associated
 * object or inlet, and a new id generated in a way which is multi-GPU
 * compatible.
 *
 * All other particle properties (position, velocity, etc) should be
 * set by the caller.
 */
__device__ __forceinline__
uint
createNewFluidParticle(
	/// [out] particle info of the generated particle
			particleinfo	&new_info,
	/// [in] particle info of the generator particle
	const	particleinfo	&info,
	/// [in] number of particles at the start of the current timestep
	const	uint			numParticles,
	/// [in] number of devices
	const	uint			numDevices,
	/// [in,out] number of particles including all the ones already created in this timestep
			uint			*newNumParticles,
	const uint			totParticles)
{
	const uint new_index = atomicAdd(newNumParticles, 1);
	// number of new particles that were created on this device
	// in this time step
	const uint newNumPartsOnDevice = new_index + 1 - numParticles;
	if (UINT_MAX - newNumPartsOnDevice*numDevices < totParticles + d_newIDsOffset) {
		printf(" FATAL: possible ID overflow in particle creation on device %d, your simulation may crash\n", d_newIDsOffset);
	}
	// ID of the new particle. Must be unique across all the GPUs: it is set
	// as the total number of particles (N) + the chosen offset (ie the device global number, G)
	// + the number of new particles on the device (k) times the total number of devices (D)
	// New_id = N + G + kD
	// Let's say for example that the simulation starts with 1M particles,
	// and that there are 3 devices (so N=10^6 and D=3),
	// with global device number G=0,1,2. Then the IDs created by each device would be:
	// for device 0: 1M + 3, 1M + 6, 1M + 9, ...
	// for device 1: 1M + 4, 1M + 7, 1M + 10, ...
	// for device 2: 1M + 5, 1M + 8, 1M + 11, ...

	const uint new_id = totParticles + newNumPartsOnDevice*numDevices + d_newIDsOffset;

	new_info = make_particleinfo_by_ids(
		PT_FLUID,
		fluid_num(info), 0, // copy the fluid number, not the object number
		new_id);
	return new_index;
}

//! Computes boundary conditions at open boundaries
/*!
 Depending on whether velocity or pressure is prescribed at a boundary the respective other component
 is computed using the appropriate Riemann invariant.
*/
__device__ __forceinline__ void
calculateIOboundaryCondition(
			float4			&eulerVel,
	const	particleinfo	info,
	const	float			rhoInt,
	const	float			rhoExt,
	const	float3			uInt,
	const	float			unInt,
	const	float			unExt,
	const	float3			normal)
{
	const int a = fluid_num(info);
	const float rInt = R(rhoInt, a);

	// impose velocity (and k,eps) => compute density
	if (VEL_IO(info)) {
		float riemannR = 0.0f;
		if (unExt <= unInt) // Expansion wave
			riemannR = rInt + (unExt - unInt);
		else { // Shock wave
			float riemannRho = RHO(P(rhoInt, a) + rhoInt * unInt * (unInt - unExt), a);
			riemannR = R(riemannRho, a);
			float riemannC = soundSpeed(riemannRho, a);
			float lambda = unExt + riemannC;
			const float cInt = soundSpeed(rhoInt, a);
			float lambdaInt = unInt + cInt;
			if (lambda <= lambdaInt) // must be a contact discontinuity then (which would actually mean lambda == lambdaInt
				riemannR = rInt;
		}
		eulerVel.w = RHOR(riemannR, a);
	}
	// impose pressure => compute velocity (normal & tangential; k and eps are already interpolated)
	else {
		float flux = 0.0f;
		// Rankine-Hugoniot is not properly working
		const float cExt = soundSpeed(rhoExt, a);
		const float cInt = soundSpeed(rhoInt, a);
		const float lambdaInt = unInt + cInt;
		const float rExt = R(rhoExt, a);
		if (rhoExt <= rhoInt) { // Expansion wave
			flux = unInt + (rExt - rInt);
			float lambda = flux + cExt;
			if (lambda > lambdaInt) { // shock wave
				flux = (P(rhoInt, a) - P(rhoExt, a))/(rhoInt*fmaxf(unInt,1e-5f*d_sscoeff[a])) + unInt;
				// check that unInt was not too small
				if (fabsf(flux) > d_sscoeff[a] * 0.1f)
					flux = unInt;
				lambda = flux + cExt;
				if (lambda <= lambdaInt) // contact discontinuity
					flux = unInt;
			}
		}
		else { // shock wave
			flux = (P(rhoInt, a) - P(rhoExt, a))/(rhoInt*fmaxf(unInt,1e-5f*d_sscoeff[a])) + unInt;
			// check that unInt was not too small
			if (fabsf(flux) > d_sscoeff[a] * 0.1f)
				flux = unInt;
			float lambda = flux + cExt;
			if (lambda <= lambdaInt) { // expansion wave
				flux = unInt + (rExt - rInt);
				lambda = flux + cExt;
				if (lambda > lambdaInt) // contact discontinuity
					flux = unInt;
			}
		}
		// AM-TODO allow imposed tangential velocity (make sure normal component is zero)
		// currently for inflow we assume that the tangential velocity is zero
		// GB-TODO FIXME splitneibs merge
        // remove normal component of imposed Eulerian velocity
		//as_float3(eulerVel) = as_float3(eulerVel) - dot(as_float3(eulerVel), normal)*normal;
		as_float3(eulerVel) = make_float3(0.0f);
		// if the imposed pressure on the boundary is negative make sure that the flux is negative
		// as well (outflow)
		if (rhoExt < d_rho0[a])
			flux = fminf(flux, 0.0f);
		// Outflow
		if (flux < 0.0f)
			// impose eulerVel according to dv/dn = 0
			// and remove normal component of velocity
			as_float3(eulerVel) = uInt - dot(uInt, normal)*normal;
		// add calculated normal velocity
		as_float3(eulerVel) += normal*flux;
		// set density to the imposed one
		eulerVel.w = rhoExt;
	}
}

//! Determines the distribution of mass based on a position on a segment
/*!
 A position inside a segment is used to split the segment area into three parts. The respective
 size of these parts are used to determine how much the mass is redistributed that is associated
 with this position. This is used in two cases:

 1.) A mass flux is given or computed for a certain segment, then the position for the function
     is equivalent to the segement position. This determines the mass flux for the vertices

 2.) A fluid particle traverses a segment. Then the position is equal to the fluid position and
     the function determines how much mass of the fluid particle is distributed to each vertex
*/
__device__ __forceinline__ void
getMassRepartitionFactor(	const	float3	*vertexRelPos,
							const	float3	normal,
									float3	&beta)
{
	float3 v01 = vertexRelPos[0]-vertexRelPos[1];
	float3 v02 = vertexRelPos[0]-vertexRelPos[2];
	float3 p0  = vertexRelPos[0]-dot(vertexRelPos[0], normal)*normal;
	float3 p1  = vertexRelPos[1]-dot(vertexRelPos[1], normal)*normal;
	float3 p2  = vertexRelPos[2]-dot(vertexRelPos[2], normal)*normal;

	float refSurface = 0.5*dot(cross(v01, v02), normal);

	float3 v21 = vertexRelPos[2]-vertexRelPos[1];

	float surface0 = 0.5*dot(cross(p2, v21), normal);
	float surface1 = 0.5*dot(cross(p0, v02), normal);
	// Warning v10 = - v01
	float surface2 = - 0.5*dot(cross(p1, v01), normal);
	if (surface0 < 0. && surface2 < 0.) {
		// the projected point is clipped to v1
		surface0 = 0.;
		surface1 = refSurface;
		surface2 = 0.;
	} else if (surface0 < 0. && surface1 < 0.) {
		// the projected point is clipped to v2
		surface0 = 0.;
		surface1 = 0.;
		surface2 = refSurface;
	} else if (surface1 < 0. && surface2 < 0.) {
		// the projected point is clipped to v0
		surface0 = refSurface;
		surface1 = 0.;
		surface2 = 0.;
	} else if (surface0 < 0.) {
		// We project p2 into the v21 line, parallel to p0
		// then surface0 is 0
		// we also modify p0 an p1 accordingly
		float coef = surface0/(0.5*dot(cross(p0, v21), normal));

		p1 -= coef*p0;
		p0 *= (1.-coef);

		surface0 = 0.;
		surface1 = 0.5*dot(cross(p0, v02), normal);
		surface2 = - 0.5*dot(cross(p1, v01), normal);
	} else if (surface1 < 0.) {
		// We project p0 into the v02 line, parallel to p1
		// then surface1 is 0
		// we also modify p1 an p2 accordingly
		float coef = surface1/(0.5*dot(cross(p1, v02), normal));
		p2 -= coef*p1;
		p1 *= (1.-coef);

		surface0 = 0.5*dot(cross(p2, v21), normal);
		surface1 = 0.;
		surface2 = - 0.5*dot(cross(p1, v01), normal);
	} else if (surface2 < 0.) {
		// We project p1 into the v01 line, parallel to p2
		// then surface2 is 0
		// we also modify p0 an p2 accordingly
		float coef = -surface2/(0.5*dot(cross(p2, v01), normal));
		p0 -= coef*p2;
		p2 *= (1.-coef);

		surface0 = 0.5*dot(cross(p2, v21), normal);
		surface1 = 0.5*dot(cross(p0, v02), normal);
		surface2 = 0.;
	}

	beta.x = surface0/refSurface;
	beta.y = surface1/refSurface;
	beta.z = surface2/refSurface;
}

// flags for the vertexinfo .w coordinate which specifies how many vertex particles of one segment
// is associated to an open boundary
#define VERTEX1 ((flag_t)1)
#define VERTEX2 (VERTEX1 << 1)
#define VERTEX3 (VERTEX2 << 1)
#define ALLVERTICES ((flag_t)(VERTEX1 | VERTEX2 | VERTEX3))

//! Computes the boundary condition on segments for SA boundaries
/*!
 This function computes the boundary condition for density/pressure on segments if the SA boundary type
 is selected. It does this not only for solid wall boundaries but also open boundaries. Additionally,
 this function detects when a fluid particle crosses the open boundary and it identifies which segment it
 crossed. The vertices of this segment are then used to identify how the mass of this fluid particle is
 split.
 \note updates are made in-place because we only read from fluids and vertex particles and only write
 boundary particles data, and no conflict can thus occurr.
 \todo templatize inputs and variables to avoid k-eps and IO inputs and variables when not needed
*/
template<KernelType kerneltype>
__global__ void
saSegmentBoundaryConditions(			float4*		__restrict__ oldPos,
										float4*		__restrict__ oldVel,
										float*		__restrict__ oldTKE,
										float*		__restrict__ oldEps,
										float4*		__restrict__ oldEulerVel,
										float4*		__restrict__ oldGGam,
										vertexinfo*	__restrict__ vertices,
								const	float2*		__restrict__ vertPos0,
								const	float2*		__restrict__ vertPos1,
								const	float2*		__restrict__ vertPos2,
								const	hashKey*	__restrict__ particleHash,
								const	uint*		__restrict__ cellStart,
								const	neibdata*	__restrict__ neibsList,
								const	uint		numParticles,
								const	float		deltap,
								const	float		slength,
								const	float		influenceradius,
								const	bool		initStep,
								const	uint		step,
								const	bool		inoutBoundaries)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if (index >= numParticles)
		return;

	// read particle data from sorted arrays
	const particleinfo info = tex1Dfetch(infoTex, index);

	if (!BOUNDARY(info))
		return;

	float4 eulerVel = make_float4(0.0f);
	const vertexinfo verts = vertices[index];
	float tke = 0.0f;
	float eps = 0.0f;

	// These summations will only run over fluid particles
	float sumpWall = 0.0f; // summation for computing the density
	float sump = 0.0f; // summation for computing the pressure
	float3 sumvel = make_float3(0.0f); // summation to compute the internal velocity for open boundaries
	float sumtke = 0.0f; // summation for computing tke (k-epsilon model)
	float sumeps = 0.0f; // summation for computing epsilon (k-epsilon model)
	float alpha  = 0.0f;  // the shepard filter

	// get the imposed quantities from the arrays which were set in the problem specific routines
	if (IO_BOUNDARY(info)) {
		// for imposed velocity the velocity, tke and eps are required and only rho will be calculated
		if (VEL_IO(info)) {
			eulerVel = oldEulerVel[index];
			eulerVel.w = 0.0f;
			if (oldTKE)
				tke = oldTKE[index];
			if (oldEps)
				eps = oldEps[index];
		}
		// for imposed density only eulerVel.w will be required, the rest will be computed
		else
			eulerVel = oldEulerVel[index];
	}

	// velocity for segment (for moving objects) taken as average from the vertices
	float4 vel = make_float4(0.0f);
	// gamma of segment (if not set) taken as average from the vertices
	float4 gGam = make_float4(0.0f, 0.0f, 0.0f, oldGGam[index].w);

	const bool calcGam = gGam.w < 1e-5f;

	// Square of sound speed. Would need modification for multifluid
	const float sqC0 = d_sqC0[fluid_num(info)];

	const float4 normal = tex1Dfetch(boundTex, index);


	const float4 pos = oldPos[index];

	// Compute grid position of current particle
	const int3 gridPos = calcGridPosFromParticleHash( particleHash[index] );

	// Persistent variables across getNeibData calls

	// Loop over VERTEX neighbors.
	// TODO this is only needed
	// (1) to compute gamma
	// (2) to compute the velocity for boundary of moving objects
	// (3) to compute the eulerian velocity for non-IO boundaries in the KEPS case
	for_each_neib(PT_VERTEX, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		// Compute relative position vector and distance
		const float4 relPos = neib_iter.relPos(oldPos[neib_index]);

		// skip inactive particles
		if (INACTIVE(relPos))
			continue;

		const particleinfo neib_info = tex1Dfetch(infoTex, neib_index);

		if (verts.x == id(neib_info) || verts.y == id(neib_info) || verts.z == id(neib_info)) {
			if (MOVING(info)) {
				const float4 neib_vel = oldVel[neib_index];
				vel.x = neib_vel.x;
				vel.y = neib_vel.y;
				vel.z = neib_vel.z;
			}
			if (calcGam)
				gGam += oldGGam[neib_index];
			if (!IO_BOUNDARY(info) && oldTKE)
				eulerVel += oldEulerVel[neib_index];
		}
	}

	// finalize gamma computation and store it
	if (calcGam) {
		gGam /= 3;
		oldGGam[index] = gGam;
		gGam.w = fmaxf(gGam.w, 1e-5f);
	}

	// finalize velocity computation. we only store it later though, because the rest of this
	// kernel may compute vel.w
	vel.x /= 3;
	vel.y /= 3;
	vel.z /= 3;


	// Loop over FLUID neighbors
	for_each_neib(PT_FLUID, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		// Compute relative position vector and distance
		// Now relPos is a float4 and neib mass is stored in relPos.w
		const float4 relPos = neib_iter.relPos(oldPos[neib_index]);

		// skip inactive particles
		if (INACTIVE(relPos))
			continue;

		const float r = length(as_float3(relPos));
		const particleinfo neib_info = tex1Dfetch(infoTex, neib_index);

		if ( !(r < influenceradius && dot3(normal, relPos) < 0.0f) )
			continue;

		const float neib_rho = oldVel[neib_index].w;
		const float neib_pres = P(neib_rho, fluid_num(neib_info));

		const float neib_vel = length(make_float3(oldVel[neib_index]));
		const float neib_k = oldTKE ? oldTKE[neib_index] : NAN;
		const float neib_eps = oldEps ? oldEps[neib_index] : NAN;

		// kernel value times volume
		const float w = W<kerneltype>(r, slength)*relPos.w/neib_rho;

		// normal distance based on grad Gamma which approximates the normal of the domain
		const float normDist = fmax(fabs(dot3(normal,relPos)), deltap);

		sumpWall += fmax(neib_pres + neib_rho*dot(d_gravity, as_float3(relPos)), 0.0f)*w;

		// for all boundaries we have dk/dn = 0
		sumtke += w*neib_k;

		if (IO_BOUNDARY(info)) {
			sumvel += w*as_float3(oldVel[neib_index] + oldEulerVel[neib_index]);
			// for open boundaries compute pressure interior state
			//sump += w*fmaxf(0.0f, neib_pres+dot(d_gravity, as_float3(relPos)*d_rho0[fluid_num(neib_info)]));
			sump += w*fmaxf(0.0f, neib_pres);
			// and de/dn = 0
			sumeps += w*neib_eps;
		} else {
			// for solid boundaries we have de/dn = c_mu^(3/4)*4*k^(3/2)/(\kappa r)
			// the constant is coming from 4*powf(0.09,0.75)/0.41
			sumeps += w*(neib_eps + 1.603090412f*powf(neib_k,1.5f)/normDist);
		}

		alpha += w;
	}

	if (IO_BOUNDARY(info)) {
		if (alpha > 0.1f*gGam.w) { // note: defaults are set in the place where bcs are imposed
			sumvel /= alpha;
			sump /= alpha;
			vel.w = RHO(sump, fluid_num(info));
			// TODO simplify branching
			if (VEL_IO(info)) {
				// for velocity imposed boundaries we impose k and epsilon
				if (oldTKE)
					oldTKE[index] = tke;
				if (oldEps)
					oldEps[index] = eps;
			} else {
				oldEulerVel[index] = make_float4(0.0f);
				// for pressure imposed boundaries we take dk/dn = 0
				if (oldTKE)
					oldTKE[index] = sumtke/alpha;
				// for pressure imposed boundaries we have de/dn = 0
				if (oldEps)
					oldEps[index] = sumeps/alpha;
			}
		} else {
			sump = 0.0f;
			if (VEL_IO(info)) {
				sumvel = as_float3(eulerVel);
				vel.w = d_rho0[fluid_num(info)];
			} else {
				sumvel = make_float3(0.0f);
				// TODO FIXME this is the logic in master, but there's something odd about this,
				// cfr assignments below [*]
				vel.w = oldEulerVel[index].w;
				oldEulerVel[index] = make_float4(0.0f, 0.0f, 0.0f, vel.w);
			}
			if (oldTKE)
				oldTKE[index] = 1e-6f;
			if (oldEps)
				oldEps[index] = 1e-6f;
		}

		// compute Riemann invariants for open boundaries
		const float unInt = dot(sumvel, as_float3(normal));
		const float unExt = dot3(eulerVel, normal);
		const float rhoInt = oldVel[index].w;
		const float rhoExt = eulerVel.w;

		calculateIOboundaryCondition(eulerVel, info, rhoInt, rhoExt, sumvel, unInt, unExt, as_float3(normal));

		// TODO FIXME cfr assignes above [*]
		oldEulerVel[index] = eulerVel;
		// the density of the particle is equal to the "eulerian density"
		vel.w = eulerVel.w;

	} else {
		// non-open boundaries
		alpha = fmaxf(alpha, 0.1f*gGam.w); // avoid division by 0
		// density condition
		vel.w = RHO(sumpWall/alpha,fluid_num(info));
		// k-epsilon boundary conditions
		if (oldTKE) {
			// k condition
			oldTKE[index] = sumtke/alpha;
			// average eulerian velocity on the wall (from associated vertices)
			eulerVel /= 3.0f;
			// ensure that velocity is normal to segment normal
			eulerVel -= dot3(eulerVel,normal)*normal;
			oldEulerVel[index] = eulerVel;
		}
		// if k-epsilon is not used but oldEulerVel is present (for open boundaries) set it to 0
		else if (oldEulerVel)
			oldEulerVel[index] = make_float4(0.0f);
		// epsilon condition
		if (oldEps)
			// for solid boundaries we have de/dn = 4 0.09^0.075 k^1.5/(0.41 r)
			oldEps[index] = fmaxf(sumeps/alpha,1e-5f); // eps should never be 0
	}


	// store recomputed velocity + pressure
	oldVel[index] = vel;

	// TODO FIXME splitneibs merge: master here had the code for FLUID particles moving through IO
	// segments
}

/// Normal computation for vertices in the initialization phase
/*! Computes a normal for vertices in the initialization phase. This normal is used in the forces
 *	computation so that gamma can be appropriately calculated for vertices, i.e. particles on a boundary.
 *	\param[out] newGGam : vertex normal vector is computed
 *	\param[in] vertices : pointer to boundary vertices table
 *	\param[in] vertIDToIndex : pointer that associated a vertex id with an array index
 *	\param[in] pinfo : pointer to particle info
 *	\param[in] particleHash : pointer to particle hash
 *	\param[in] cellStart : pointer to indices of first particle in cells
 *	\param[in] neibsList : neighbour list
 *	\param[in] numParticles : number of particles
 */
template<KernelType kerneltype>
__global__ void
computeVertexNormal(
						float4*			boundelement,
				const	vertexinfo*		vertices,
				const	particleinfo*	pinfo,
				const	hashKey*		particleHash,
				const	uint*			cellStart,
				const	neibdata*		neibsList,
				const	uint			numParticles)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if (index >= numParticles)
		return;

	// read particle data from sorted arrays
	// kernel is only run for vertex particles
	const particleinfo info = pinfo[index];
	if (!VERTEX(info))
		return;

	float4 pos = make_float4(0.0f);
	uint our_id = id(info);

	// Average norm used in the initial step to compute grad gamma for vertex particles
	// During the simulation this is used for open boundaries to determine whether particles are created
	// For all other boundaries in the keps case this is the average normal of all non-open boundaries used to ensure that the
	// Eulerian velocity is only normal to the fixed wall
	float3 avgNorm = make_float3(0.0f);

	// Compute grid position of current particle
	const int3 gridPos = calcGridPosFromParticleHash( particleHash[index] );

	// Loop over all BOUNDARY neighbors
	for_each_neib(PT_BOUNDARY, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();
		const particleinfo neib_info = pinfo[neib_index];

		// Skip this neighboring boundary element if it's not in the same boundary
		// classification as us, i.e. if it's an IO boundary element and we are not
		// an IO vertex, or if the boundary element is not IO and we are an IO vertex.
		// The check is done by negating IO_BOUNDARY because IO_BOUNDARY returns
		// the combination of FG_INLET and FG_OUTLET pertaining to the particle,
		// and we don't care about that aspect, we only care about IO vs non-IO
		if (!IO_BOUNDARY(info) != !IO_BOUNDARY(neib_info))
			continue;

		const vertexinfo neib_verts = vertices[neib_index];
		const float4 boundElement = boundelement[neib_index];

		// check if vertex is associated with this segment
		if (neib_verts.x == our_id || neib_verts.y == our_id || neib_verts.z == our_id) {
			// in the initial step we need to compute an approximate grad gamma direction
			// for the computation of gamma, in general we need a sort of normal as well
			// for open boundaries to decide whether or not particles are created at a
			// vertex or not, finally for k-epsilon we need the normal to ensure that the
			// velocity in the wall obeys v.n = 0
			avgNorm += as_float3(boundElement)*boundElement.w;
		}
	}

	// normalize average norm. The .w component for vertices is not used
	boundelement[index] = make_float4(normalize(avgNorm), NAN);
}

/// Initializes gamma using quadrature formula
/*! In the dynamic gamma case gamma is computed using a transport equation. Thus an initial value needs
 *	to be computed. In this kernel this value is determined using a numerical integration. As this integration
 *	has its problem when particles are close to the wall, it's not useful with open boundaries, but at the
 *	initial time-step particles should be far enough away.
 *	\param[out] newGGam : vertex normal vector is computed
 *	\param[in] oldPos : particle positions
 *	\param[in] boundElement : pointer to vertex & segment normals
 *	\param[in] pinfo : pointer to particle info
 *	\param[in] particleHash : pointer to particle hash
 *	\param[in] cellStart : pointer to indices of first particle in cells
 *	\param[in] neibsList : neighbour list
 *	\param[in] slength : smoothing length
 *	\param[in] influenceradius : kernel radius
 *	\param[in] deltap : particle size
 *	\param[in] epsilon : numerical epsilon
 *	\param[in] numParticles : number of particles
 */
template<KernelType kerneltype, ParticleType cptype>
__global__ void
initGamma(
						float4*			newGGam,
				const	float4*			oldPos,
				const	float4*			boundElement,
				const	float2*			vertPos0,
				const	float2*			vertPos1,
				const	float2*			vertPos2,
				const	particleinfo*	pinfo,
				const	hashKey*		particleHash,
				const	uint*			cellStart,
				const	neibdata*		neibsList,
				const	float			slength,
				const	float			influenceradius,
				const	float			deltap,
				const	float			epsilon,
				const	uint			numParticles)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if (index >= numParticles)
		return;

	// read particle data from sorted arrays
	// kernel is only run for vertex particles
	const particleinfo info = pinfo[index];
	if (type(info) != cptype)
		return;

	float4 pos = oldPos[index];

	// gamma that is to be computed
	float gam = 1.0f;
	// grad gamma
	float3 gGam = make_float3(0.0f);

	// Compute grid position of current particle
	const int3 gridPos = calcGridPosFromParticleHash( particleHash[index] );

	// Iterate over all BOUNDARY neighbors
	for_each_neib(PT_BOUNDARY, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		const float3 relPos = as_float3(neib_iter.relPos(oldPos[neib_index]));

		if (length(relPos) > influenceradius + deltap*0.5f)
			continue;

		const float3 normal = as_float3(boundElement[neib_index]);

		// local coordinate system for relative positions to vertices
		uint j = 0;
		// Get index j for which n_s is minimal
		if (fabsf(normal.x) > fabsf(normal.y))
			j = 1;
		if ((1-j)*fabsf(normal.x) + j*fabsf(normal.y) > fabsf(normal.z))
			j = 2;

		// compute the first coordinate which is a 2-D rotated version of the normal
		const float3 coord1 = normalize(make_float3(
					// switch over j to give: 0 -> (0, z, -y); 1 -> (-z, 0, x); 2 -> (y, -x, 0)
					-((j==1)*normal.z) +  (j == 2)*normal.y , // -z if j == 1, y if j == 2
					(j==0)*normal.z  - ((j == 2)*normal.x), // z if j == 0, -x if j == 2
					-((j==0)*normal.y) +  (j == 1)*normal.x // -y if j == 0, x if j == 1
					));
		// the second coordinate is the cross product between the normal and the first coordinate
		const float3 coord2 = cross(normal, coord1);

		// relative positions of vertices with respect to the segment
		const float3 qva = -(vertPos0[neib_index].x*coord1 + vertPos0[neib_index].y*coord2)/slength; // e.g. v0 = r_{v0} - r_s
		const float3 qvb = -(vertPos1[neib_index].x*coord1 + vertPos1[neib_index].y*coord2)/slength;
		const float3 qvc = -(vertPos2[neib_index].x*coord1 + vertPos2[neib_index].y*coord2)/slength;
		float3 q_vb[3] = {qva, qvb, qvc};
		const float3 q = relPos/slength;

		const float ggamma_as = gradGamma<kerneltype>(slength, q, q_vb, normal);
		gGam += ggamma_as*normal;

		const float gamma_as = Gamma<kerneltype, cptype>(slength, q, q_vb, normal,
					as_float3(newGGam[index]), epsilon);
		gam -= gamma_as;
	}

	newGGam[index] = make_float4(gGam.x, gGam.y, gGam.z, gam);
}

#define MAXNEIBVERTS 30

/// Modifies the initial mass of vertices on open boundaries
/*! This function computes the initial value of \f[\gamma\f] in the semi-analytical boundary case, using a Gauss quadrature formula.
 *	\param[out] newGGam : pointer to the new value of (grad) gamma
 *	\param[in,out] boundelement : normal of segments and of vertices (the latter is computed in this routine)
 *	\param[in] oldPos : pointer to positions and masses; masses of vertex particles are updated
 *	\param[in] oldGGam : pointer to (grad) gamma; used as an approximate normal to the boundary in the computation of gamma
 *	\param[in] vertPos[0] : relative position of the vertex 0 with respect to the segment center
 *	\param[in] vertPos[1] : relative position of the vertex 1 with respect to the segment center
 *	\param[in] vertPos[2] : relative position of the vertex 2 with respect to the segment center
 *	\param[in] pinfo : pointer to particle info; written only when cloning
 *	\param[in] particleHash : pointer to particle hash; written only when cloning
 *	\param[in] cellStart : pointer to indices of first particle in cells
 *	\param[in] neibsList : neighbour list
 *	\param[in] numParticles : number of particles
 *	\param[in] slength : the smoothing length
 *	\param[in] influenceradius : the kernel radius
 */
template<KernelType kerneltype>
__global__ void
__launch_bounds__(BLOCK_SIZE_SA_BOUND, MIN_BLOCKS_SA_BOUND)
initIOmass_vertexCount(
				const	vertexinfo*		vertices,
				const	hashKey*		particleHash,
				const	particleinfo*	pinfo,
				const	uint*			cellStart,
				const	neibdata*		neibsList,
						float4*			forces,
				const	uint			numParticles)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if (index >= numParticles)
		return;

	// read particle data from sorted arrays
	// kernel is only run for vertex particles
	const particleinfo info = pinfo[index];
	if (!(VERTEX(info) && IO_BOUNDARY(info) && !CORNER(info)))
		return;

	// Persistent variables across getNeibData calls
	uint vertexCount = 0;

	const float4 pos = make_float4(0.0f); // we don't need pos, so let's just set it to 0
	const int3 gridPos = calcGridPosFromParticleHash( particleHash[index] );

	uint neibVertIds[MAXNEIBVERTS];
	uint neibVertIdsCount=0;

	// Loop over all BOUNDARY neighbors
	for_each_neib(PT_BOUNDARY, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		const particleinfo neib_info = pinfo[neib_index];

		// only IO boundary neighbours as we need to count the vertices that belong to the same segment as our vertex particle
		if (IO_BOUNDARY(neib_info)) {

			// prepare ids of neib vertices
			const vertexinfo neibVerts = vertices[neib_index];

			// only check adjacent boundaries
			if (neibVerts.x == id(info) || neibVerts.y == id(info) || neibVerts.z == id(info)) {
				// check if we don't have the current vertex
				if (id(info) != neibVerts.x) {
					neibVertIds[neibVertIdsCount] = neibVerts.x;
					neibVertIdsCount+=1;
				}
				if (id(info) != neibVerts.y) {
					neibVertIds[neibVertIdsCount] = neibVerts.y;
					neibVertIdsCount+=1;
				}
				if (id(info) != neibVerts.z) {
					neibVertIds[neibVertIdsCount] = neibVerts.z;
					neibVertIdsCount+=1;
				}
			}

		}
	}

	// Loop over all VERTEX neighbors
	for_each_neib(PT_VERTEX, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		const particleinfo neib_info = pinfo[neib_index];

		for (uint j = 0; j<neibVertIdsCount; j++) {
			if (id(neib_info) == neibVertIds[j] && !CORNER(neib_info))
				vertexCount += 1;
		}
	}

	forces[index].w = (float)(vertexCount);
}

template<KernelType kerneltype>
__global__ void
__launch_bounds__(BLOCK_SIZE_SA_BOUND, MIN_BLOCKS_SA_BOUND)
initIOmass(
				const	float4*			oldPos,
				const	float4*			forces,
				const	vertexinfo*		vertices,
				const	hashKey*		particleHash,
				const	particleinfo*	pinfo,
				const	uint*			cellStart,
				const	neibdata*		neibsList,
						float4*			newPos,
				const	uint			numParticles,
				const	float			deltap)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if (index >= numParticles)
		return;

	const particleinfo info = pinfo[index];
	const float4 pos = oldPos[index];
	newPos[index] = pos;

	// read particle data from sorted arrays
	// kernel is only run for vertex particles
	//const particleinfo info = pinfo[index];
	if (!(VERTEX(info) && IO_BOUNDARY(info) && !CORNER(info)))
		return;

	const int3 gridPos = calcGridPosFromParticleHash( particleHash[index] );

	// does this vertex get or donate mass; decided by the id of a vertex particle
	const bool getMass = id(info)%2;
	float massChange = 0.0f;

	const float refMass = 0.5f*deltap*deltap*deltap*d_rho0[fluid_num(info)]; // half of the fluid mass

	// difference between reference mass and actual mass of particle
	const float massDiff = refMass - pos.w;
	// number of vertices associated with the same boundary segment as this vertex (that are also IO)
	const float vertexCount = forces[index].w;

	uint neibVertIds[MAXNEIBVERTS];
	uint neibVertIdsCount=0;

	// Loop over all BOUNDARY neighbors
	for_each_neib(PT_BOUNDARY, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		const particleinfo neib_info = pinfo[neib_index];

		// only IO boundary neighbours as we need to count the vertices that belong to the same segment as our vertex particle
		if (!IO_BOUNDARY(neib_info))
			continue;

		// prepare ids of neib vertices
		const vertexinfo neibVerts = vertices[neib_index];

		// only check adjacent boundaries
		if (neibVerts.x == id(info) || neibVerts.y == id(info) || neibVerts.z == id(info)) {
			// check if we don't have the current vertex
			if (id(info) != neibVerts.x) {
				neibVertIds[neibVertIdsCount] = neibVerts.x;
				neibVertIdsCount+=1;
			}
			if (id(info) != neibVerts.y) {
				neibVertIds[neibVertIdsCount] = neibVerts.y;
				neibVertIdsCount+=1;
			}
			if (id(info) != neibVerts.z) {
				neibVertIds[neibVertIdsCount] = neibVerts.z;
				neibVertIdsCount+=1;
			}
		}
	}

	// Loop over all VERTEX neighbors
	for_each_neib(PT_BOUNDARY, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		const particleinfo neib_info = pinfo[neib_index];

		for (uint j = 0; j<neibVertIdsCount; j++) {
			if (id(neib_info) == neibVertIds[j]) {
				const bool neib_getMass = id(neib_info)%2;
				if (getMass != neib_getMass && !CORNER(neib_info)) { // if not both vertices get or donate mass
					if (getMass) {// original vertex gets mass
						if (massDiff > 0.0f)
							massChange += massDiff/vertexCount; // get mass from all adjacent vertices equally
					}
					else {
						const float neib_massDiff = refMass - oldPos[neib_index].w;
						if (neib_massDiff > 0.0f) {
							const float neib_vertexCount = forces[neib_index].w;
							massChange -= neib_massDiff/neib_vertexCount; // get mass from this vertex
						}
					}
				}
			}
		}
	}

	newPos[index].w += massChange;
}

/// Compute boundary conditions for vertex particles in the semi-analytical boundary case
/*! This function determines the physical properties of vertex particles in the semi-analytical boundary case. The properties of fluid particles are used to compute the properties of the vertices. Due to this most arrays are read from (the fluid info) and written to (the vertex info) simultaneously inside this function. In the case of open boundaries the vertex mass is updated in this routine and new fluid particles are created on demand. Additionally, the mass of outgoing fluid particles is redistributed to vertex particles herein.
 *	\param[in,out] oldPos : pointer to positions and masses; masses of vertex particles are updated
 *	\param[in,out] oldVel : pointer to velocities and density; densities of vertex particles are updated
 *	\param[in,out] oldTKE : pointer to turbulent kinetic energy
 *	\param[in,out] oldEps : pointer to turbulent dissipation
 *	\param[in,out] oldGGam : pointer to (grad) gamma; used only for cloning (i.e. creating a new particle)
 *	\param[in,out] oldEulerVel : pointer to Eulerian velocity & density; imposed values are set and the other is computed here
 *	\param[in,out] forces : pointer to forces; used only for cloning
 *	\param[in,out] dgamdt : pointer to dgamdt; used only for cloning
 *	\param[in,out] vertices : pointer to associated vertices; fluid particles have this information if they are passing through a boundary and are going to be deleted
 *	\param[in] vertIDToIndex : pointer that associated a vertex id with an array index
 *	\param[in,out] pinfo : pointer to particle info; written only when cloning
 *	\param[in,out] particleHash : pointer to particle hash; written only when cloning
 *	\param[in] cellStart : pointer to indices of first particle in cells
 *	\param[in] neibsList : neighbour list
 *	\param[in] numParticles : number of particles
 *	\param[out] newNumParticles : number of particles after creation of new fluid particles due to open boundaries
 *	\param[in] dt : time-step size
 *	\param[in] step : the step in the time integrator
 *	\param[in] deltap : the particle size
 *	\param[in] slength : the smoothing length
 *	\param[in] influenceradius : the kernel radius
 *	\param[in] deviceId : current device identifier
 *	\param[in] numDevices : total number of devices; used for id generation of new fluid particles
 */
template<KernelType kerneltype>
__global__ void
saVertexBoundaryConditions(
						float4*			oldPos,
						float4*			oldVel,
						float*			oldTKE,
						float*			oldEps,
						float4*			oldGGam,
						float4*			oldEulerVel,
						float4*			forces,
						float*			dgamdt,
						vertexinfo*		vertices,
				const	float2*			vertPos0,
				const	float2*			vertPos1,
				const	float2*			vertPos2,
						particleinfo*	pinfo,
						hashKey*		particleHash,
				const	uint*			cellStart,
				const	neibdata*		neibsList,
				const	uint			numParticles,
						uint*			newNumParticles,
				const	float			dt,
				const	int				step,
				const	float			deltap,
				const	float			slength,
				const	float			influenceradius,
				const	bool			initStep,
				const	bool			resume,
				const	uint			deviceId,
				const	uint			numDevices)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if (index >= numParticles)
		return;

	// read particle data from sorted arrays
	// kernel is only run for vertex particles
	const particleinfo info = pinfo[index];
	if (!VERTEX(info))
		return;

	float4 pos = oldPos[index];

	// these are taken as the sum over all adjacent segments
	float sumpWall = 0.0f; // summation for computing the density
	float alpha = 0.0f; // summation of normalization for IO boundaries

	// Compute grid position of current particle
	const int3 gridPos = calcGridPosFromParticleHash( particleHash[index] );

	// Persistent variables across getNeibData calls
	char neib_cellnum = 0;
	uint neib_cell_base_index = 0;
	float3 pos_corr;

	const float gam = oldGGam[index].w;
	const float sqC0 = d_sqC0[fluid_num(info)];

	idx_t i = 0;

	// Loop over all the neighbors
	// TODO FIXME splitneibs merge : check logic against master
	while (true) {
		neibdata neib_data = neibsList[i + index];

		if (neib_data == 0xffff) break;
		i += d_neiblist_stride;

		const uint neib_index = getNeibIndex(pos, pos_corr, cellStart, neib_data, gridPos,
					neib_cellnum, neib_cell_base_index);

		const float4 relPos = pos_corr - oldPos[neib_index];

		const float r = length(as_float3(relPos));
		if (r < influenceradius){
			const particleinfo neib_info = pinfo[neib_index];
			const float neib_rho = oldVel[neib_index].w;
			const float neib_pres = P(neib_rho, fluid_num(neib_info));

			// kernel value times volume
			const float w = W<kerneltype>(r, slength)*relPos.w/neib_rho;
			sumpWall += fmax(neib_pres + neib_rho*dot(d_gravity, as_float3(relPos)), 0.0f)*w;
			alpha += w;
		}

	}

	// update boundary conditions on array
	// note that numseg should never be zero otherwise you found a bug
	alpha = fmax(alpha, 0.1f*gam); // avoid division by 0
	oldVel[index].w = RHO(sumpWall/alpha,fluid_num(info));
}

//! Identify corner vertices on open boundaries
/*!
 Corner vertices are vertices that have segments that are not part of an open boundary. These
 vertices are treated slightly different when imposing the boundary conditions during the
 computation in saVertexBoundaryConditions.
*/
__global__ void
saIdentifyCornerVertices(
				const	float4*			oldPos,
						particleinfo*	pinfo,
				const	hashKey*		particleHash,
				const	vertexinfo*		vertices,
				const	uint*			cellStart,
				const	neibdata*		neibsList,
				const	uint			numParticles,
				const	float			deltap,
				const	float			eps)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if (index >= numParticles)
		return;

	// read particle data from sorted arrays
	// kernel is only run for vertex particles which are associated to an open boundary
	particleinfo info = pinfo[index];
	const uint obj = object(info);
	if (!(VERTEX(info) && IO_BOUNDARY(info)))
		return;

	float4 pos = oldPos[index];

	// Compute grid position of current particle
	const int3 gridPos = calcGridPosFromParticleHash( particleHash[index] );

	const uint vid = id(info);

	// Loop over all BOUNDARY neighbors
	for_each_neib(PT_BOUNDARY, index, pos, gridPos, cellStart, neibsList) {
		const uint neib_index = neib_iter.neib_index();

		const particleinfo neib_info = pinfo[neib_index];
		const uint neib_obj = object(neib_info);

		// loop only over boundary elements that are not of the same open boundary
		if (!(obj == neib_obj && IO_BOUNDARY(neib_info))) {
			// check if the current vertex is part of the vertices of the segment
			if (vertices[neib_index].x == vid ||
				vertices[neib_index].y == vid ||
				vertices[neib_index].z == vid) {
				SET_FLAG(info, FG_CORNER);
				pinfo[index] = info;
				break;
			}
		}
	}
}

//! Disables particles that have exited through an open boundary
/*!
 This kernel is only used for SA boundaries in combination with the outgoing particle identification
 in saSegmentBoundaryConditions(). If a particle crosses a segment then the vertexinfo array is set
 for this fluid particle. This is used here to identify such particles. In turn the vertexinfo array
 is reset and the particle is disabled.
*/
__global__ void
disableOutgoingPartsDevice(			float4*		oldPos,
									vertexinfo*	oldVertices,
							const	uint		numParticles)
{
	const uint index = INTMUL(blockIdx.x,blockDim.x) + threadIdx.x;

	if(index < numParticles) {
		const particleinfo info = tex1Dfetch(infoTex, index);
		if (FLUID(info)) {
			float4 pos = oldPos[index];
			if (ACTIVE(pos)) {
				vertexinfo vertices = oldVertices[index];
				if (vertices.x | vertices.y != 0) {
					disable_particle(pos);
					vertices.x = 0;
					vertices.y = 0;
					vertices.z = 0;
					vertices.w = 0;
					oldPos[index] = pos;
					oldVertices[index] = vertices;
				}
			}
		}
	}
}

/** @} */

} // namespace cubounds

#endif