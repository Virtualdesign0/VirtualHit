--!strict

-- Shape descriptors are frozen the moment they are built -- that is a documented
-- promise of this library, not an implementation detail -- so the fields are
-- declared read-only. Without that the type says a caller may write to a
-- descriptor it cannot write to, and the analyser has to reject every
-- table.freeze that produces one.
export type RayShape = {
	read Type: "Ray",
}

export type SphereShape = {
	read Type: "Sphere",
	read Radius: number,
}

export type BlockShape = {
	read Type: "Block",
	read Size: Vector3,
}

export type PartShape = {
	read Type: "Part",
	read Part: BasePart,
	read Offset: CFrame,
}

-- A compound member is always a primitive. Nesting compounds would make the
-- member index reported on a hit ambiguous, and buys no expressiveness: any
-- nested tree flattens to the same ordered list of primitives.
export type PrimitiveShape = SphereShape | BlockShape | PartShape

export type CompoundMember = {
	read Shape: PrimitiveShape,
	read Offset: CFrame,
}

export type CompoundShape = {
	read Type: "Compound",
	read Members: { CompoundMember },
}

export type CastShape = RayShape | SphereShape | BlockShape | PartShape
export type OverlapShape = SphereShape | BlockShape | PartShape | CompoundShape
export type SweepShape = OverlapShape
export type CastOrigin = Vector3 | CFrame

export type EntityResolver = (instance: BasePart) -> Instance?

-- Classifies a part inside an entity: "Head", "Torso", "Limb", and so on.
-- Unrelated to VirtualHit.zone(), which is a persistent area query.
export type ZoneResolver = (instance: BasePart) -> string?

export type Predicate = (instance: BasePart) -> boolean

export type HitResult = {
	Instance: BasePart,
	Position: Vector3,
	Normal: Vector3,
	Material: Enum.Material,
	-- Ray: origin-to-contact distance. Sphere/Block/Part: distance travelled by
	-- the shape's origin before contact. This is the native result meaning.
	Distance: number,
	Entity: Instance?,
	Zone: string?,
}

-- Overlap queries have no unique contact position or surface normal, so they
-- intentionally use a smaller truthful result instead of synthetic HitResults.
export type OverlapHit = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
}

-- A radial query is an overlap plus one line-of-sight ray per candidate. The
-- distance is measured to the candidate's closest surface point, never to its
-- centre, so a large part is not penalised for the position of its origin.
export type RadialHit = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Distance: number,
	Point: Vector3,
	Occluded: boolean,
	Blocker: BasePart?,
}

export type HitResponse = "Hit" | "Block" | "Ignore"

-- Pose is where the member that made contact was; RootPose is where the sweep
-- itself was at the same instant. For a single-primitive shape with no offset
-- the two are the same CFrame, which is why the difference stays invisible
-- until a Compound or an offset member is what actually touched something.
-- Anything moving a body to the contact -- a projectile stopping at a wall --
-- wants RootPose. Anything drawing the contact wants Pose.

export type SweepOverlapCandidate = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Kind: "Overlap",
	Member: number,
	Alpha: number,
	Pose: CFrame,
	RootPose: CFrame,
	Result: nil,
}

export type SweepContactCandidate = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Kind: "Sweep",
	Member: number,
	Alpha: number,
	Pose: CFrame,
	RootPose: CFrame,
	Result: HitResult,
}

export type SweepCandidate = SweepOverlapCandidate | SweepContactCandidate

export type SweepOverlapHit = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Kind: "Overlap",
	Member: number,
	Alpha: number,
	Pose: CFrame,
	RootPose: CFrame,
	Result: nil,
	Response: "Hit",
}

export type SweepContactHit = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Kind: "Sweep",
	Member: number,
	Alpha: number,
	Pose: CFrame,
	RootPose: CFrame,
	Result: HitResult,
	Response: "Hit",
}

export type SweepHit = SweepOverlapHit | SweepContactHit

export type SweepOverlapBlock = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Kind: "Overlap",
	Member: number,
	Alpha: number,
	Pose: CFrame,
	RootPose: CFrame,
	Result: nil,
	Response: "Block",
}

export type SweepContactBlock = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Kind: "Sweep",
	Member: number,
	Alpha: number,
	Pose: CFrame,
	RootPose: CFrame,
	Result: HitResult,
	Response: "Block",
}

export type SweepBlock = SweepOverlapBlock | SweepContactBlock

return {}
