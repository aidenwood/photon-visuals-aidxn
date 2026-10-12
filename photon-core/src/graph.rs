//! Cook graph — placement, ordering, dirty tracking and batching.
//!
//! Nodes declare `(domain, rate)`: GPU textures cook at composition rate, CPU
//! channels and DMX at their own. Domain crossings are explicit nodes, and a
//! GPU to CPU crossing is an asynchronous, bounded, consumer-rate readback.
//!
//! This module is a **pure data structure**. It decides *what* must cook, *where*
//! each node runs and *in what order* — it never executes anything, touches I/O
//! or spawns a thread. The shell's scheduler does that, driven by a [`CookPlan`].
//!
//! ## The four rules this type exists to enforce
//!
//! 1. **Every node declares `(domain, rate)`.** A 120 Hz composition feeding a
//!    DMX universe is two clocks, not one: DMX512 is ~44 Hz at the wire and no
//!    amount of GPU headroom changes that. A graph that assumes a single rate
//!    either starves the screen or lies to the fixtures.
//!
//! 2. **A domain crossing is a node, never a property of an edge.** An implicit
//!    crossing is an unaccounted stall — the readback has a size, a latency, a
//!    bound on how many may be in flight, and a rate that belongs to the
//!    *consumer*, not the producer. None of that can live on an edge, so an
//!    edge that would cross is rejected ([`GraphError::ImplicitCrossing`]) and
//!    the operator must place a [`Node::crossing`]. "No CPU readback ever" was
//!    wrong (`docs/scaffold.md` §5); unbounded, uncounted readback is what is
//!    actually wrong.
//!
//! 3. **Dirty is a generation, not a boolean.** A boolean cannot answer "cooked
//!    against *which* version", so a multi-input node silently misses the input
//!    that moved least. Each edge remembers the producer generation it last
//!    cooked against. A near-static *video* source is not an unchanged node —
//!    it still advances timestamps and decodes — so time-dependence is declared
//!    separately from value change ([`Node::driven_by_time`]).
//!
//! 4. **Feedback is a temporal edge, not a cycle.** Reading the previous frame
//!    is legitimate and common (trails, feedback buffers); reading the *current*
//!    frame of a downstream node is an error with no fixed point. Both look like
//!    a loop in the adjacency list, so they are distinguished at construction:
//!    [`CookGraph::connect_delayed`] carries data without constraining order.
//!
//! ## Plan, then commit
//!
//! [`CookGraph::plan`] takes `&self` and mutates nothing. Generations advance
//! only in [`CookGraph::commit`], and only for the nodes the scheduler reports
//! as actually cooked — a node planned but dropped on a missed deadline stays
//! dirty and is re-planned next pass, instead of being quietly marked clean.

use std::collections::{BTreeMap, BTreeSet};

use crate::doc::{Id, Rational};

// ── placement ────────────────────────────────────────────────────────────────

/// Where a node's work physically runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Domain {
    /// Texture work: anything whose result lives in GPU memory.
    Gpu,
    /// Scalar, sample and event work: parameters, envelopes, DMX, OSC, MIDI.
    Cpu,
    /// Expressible in either domain — a constant, a curve, a scalar mix.
    ///
    /// Resolved from context so the node joins a neighbour's batch rather than
    /// forcing a crossing. Never appears in a resolved [`Placement`].
    Either,
}

impl std::fmt::Display for Domain {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Gpu => "GPU",
            Self::Cpu => "CPU",
            Self::Either => "either",
        })
    }
}

/// A node's declared cadence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rate {
    /// Take the cadence of whatever drives this node.
    ///
    /// Resolved from the fastest upstream producer; a node with no resolved
    /// producer takes the composition rate if it lands on [`Domain::Gpu`]
    /// (the composition clock *is* the GPU clock), and otherwise takes its
    /// consumers' rate — which is how a CPU chain ends up running at the DMX
    /// rate rather than at 60 Hz.
    Inherit,
    /// A cadence of its own, independent of upstream. DMX sinks, LFOs, and
    /// anything pinned to hardware that cannot be hurried.
    Fixed(Rational),
    /// No cadence: cooks only when an input or a parameter actually changes.
    OnChange,
}

/// A node's resolved cadence.
///
/// Distinct from [`Rate`] because `Inherit` is a question, not an answer — a
/// scheduler can only dispatch something that has been resolved to one of these.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CookRate {
    /// Cooks on a fixed cadence.
    Periodic(Rational),
    /// Cooks only when something upstream changes.
    OnChange,
}

impl CookRate {
    /// Cadence in hertz, lossily. `None` for [`CookRate::OnChange`].
    ///
    /// For display and cost reporting only — never for accumulating time.
    #[must_use]
    pub fn hz(self) -> Option<f64> {
        match self {
            Self::Periodic(r) => Some(r.to_f64()),
            Self::OnChange => None,
        }
    }

    /// Exact period between cooks. `None` for [`CookRate::OnChange`].
    #[must_use]
    pub fn period(self) -> Option<Rational> {
        match self {
            Self::Periodic(r) if r.num() != 0 => Some(r.recip()),
            _ => None,
        }
    }

    /// Whether this cadence is clock-driven rather than event-driven.
    #[must_use]
    pub const fn is_periodic(self) -> bool {
        matches!(self, Self::Periodic(_))
    }
}

/// A node's resolved domain and cadence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    /// Resolved domain. Never [`Domain::Either`].
    pub domain: Domain,
    /// Resolved cadence.
    pub rate: CookRate,
}

// ── nodes ────────────────────────────────────────────────────────────────────

/// What a domain crossing costs, declared by whoever placed it.
///
/// The graph cannot measure a transfer, but it can refuse to pretend one is
/// free: every crossing carries its size and its bound, and [`CookPlan`] adds
/// them up. An unbounded readback is rejected outright — unbounded means the
/// consumer eventually blocks the producer, which is a dropped frame wearing a
/// different hat.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CrossingCost {
    /// Bytes moved per cook.
    pub bytes: u64,
    /// How many transfers may be in flight before the consumer must wait.
    ///
    /// Also the crossing's latency in cooks: results arrive this many cooks
    /// after the frame they were taken from.
    pub max_in_flight: u32,
}

impl CrossingCost {
    /// A crossing of `bytes` with `max_in_flight` transfers outstanding.
    #[must_use]
    pub const fn new(bytes: u64, max_in_flight: u32) -> Self {
        Self {
            bytes,
            max_in_flight,
        }
    }
}

/// What a node does, for the purposes of scheduling it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind {
    /// Ordinary work, entirely inside one domain.
    Op,
    /// An explicit domain crossing: readback, upload, or sample conversion.
    ///
    /// The node's [`Node::domain`] is the domain its *output* lands in — the
    /// consumer side — which is also the side whose rate it runs at.
    Crossing {
        /// Domain the input is read from. Must differ from the node's domain.
        from: Domain,
        /// Declared transfer size and in-flight bound.
        cost: CrossingCost,
    },
}

/// One node in the cook graph.
///
/// Identity is the document [`Id`] of whatever the node serves, so a plan can
/// be correlated with the document and with telemetry without a second table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Node {
    /// Stable identity.
    pub id: Id,
    /// Domain this node's *output* lives in. [`Domain::Either`] is resolved
    /// from context.
    pub domain: Domain,
    /// Declared cadence.
    pub rate: Rate,
    /// Ordinary work, or an explicit crossing.
    pub kind: NodeKind,
    /// Whether this node advances with time regardless of its inputs.
    ///
    /// The distinction requirement 3 exists for: a video source whose picture
    /// barely changes is still decoding and still advancing its timestamp, so
    /// it is dirty every pass. A still image with the same inputs is not.
    pub time_dependent: bool,
}

impl Node {
    /// Ordinary work in one domain.
    #[must_use]
    pub const fn op(id: Id, domain: Domain, rate: Rate) -> Self {
        Self {
            id,
            domain,
            rate,
            kind: NodeKind::Op,
            time_dependent: false,
        }
    }

    /// An explicit domain crossing from `from` into `to`.
    ///
    /// Defaults to [`Rate::Inherit`], which for a crossing resolves from its
    /// *consumers* — the whole point of making the crossing a node.
    #[must_use]
    pub const fn crossing(id: Id, from: Domain, to: Domain, cost: CrossingCost) -> Self {
        Self {
            id,
            domain: to,
            rate: Rate::Inherit,
            kind: NodeKind::Crossing { from, cost },
            time_dependent: false,
        }
    }

    /// Marks the node as advancing with time: dirty on every pass.
    #[must_use]
    pub fn driven_by_time(mut self) -> Self {
        self.time_dependent = true;
        self
    }

    /// Overrides the declared cadence.
    #[must_use]
    pub fn at_rate(mut self, rate: Rate) -> Self {
        self.rate = rate;
        self
    }

    /// Whether this node is an explicit domain crossing.
    #[must_use]
    pub const fn is_crossing(&self) -> bool {
        matches!(self.kind, NodeKind::Crossing { .. })
    }
}

// ── edges ────────────────────────────────────────────────────────────────────

/// When a consumer sees its producer's result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EdgeTiming {
    /// This pass. Constrains cook order; participates in cycle detection.
    Immediate,
    /// Last pass — feedback. Carries data but imposes no ordering, because the
    /// value already exists before the pass begins.
    Delayed,
}

/// A dependency between two nodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Edge {
    /// Producer.
    pub from: Id,
    /// Consumer.
    pub to: Id,
    /// Immediate, or delayed by one pass.
    pub timing: EdgeTiming,
}

#[derive(Debug, Clone, Copy)]
struct EdgeRec {
    from: usize,
    to: usize,
    timing: EdgeTiming,
    /// Producer generation the consumer last cooked this input against.
    ///
    /// Per edge, not per node: a single watermark per node is wrong the moment
    /// a node has two inputs at different generations, because the input that
    /// moved would be masked by the input that is already higher.
    seen: Generation,
}

// ── generations ──────────────────────────────────────────────────────────────

/// A monotonic version stamp on a node's output.
///
/// Comparisons answer "has this input moved since I last used it", which a
/// boolean cannot. Advances only in [`CookGraph::commit`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct Generation(u64);

impl Generation {
    /// The generation of a node that has never cooked.
    pub const NEVER: Self = Self(0);

    /// The raw counter, for telemetry and FFI.
    #[must_use]
    pub const fn raw(self) -> u64 {
        self.0
    }

    const fn next(self) -> Self {
        Self(self.0 + 1)
    }
}

impl std::fmt::Display for Generation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "g{}", self.0)
    }
}

// ── errors ───────────────────────────────────────────────────────────────────

/// Why a graph could not be built or planned.
///
/// All of these are editor-time mistakes, reported with enough detail to
/// highlight the offending node or edge in a patch view. None of them are
/// recoverable by guessing: silently inserting a readback, or silently breaking
/// a loop, produces a graph the operator did not author.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GraphError {
    /// Referenced a node that is not in the graph.
    #[error("node {0} is not in the graph")]
    UnknownNode(Id),
    /// Added a node whose id is already present.
    #[error("node {0} is already in the graph")]
    DuplicateNode(Id),
    /// Immediate edges form a loop with no fixed point.
    #[error(
        "cycle through {}; use a delayed edge if this is feedback",
        DisplayPath(.nodes)
    )]
    Cycle {
        /// The loop, in edge order. The last node feeds the first.
        nodes: Vec<Id>,
    },
    /// An edge moves data between domains without a crossing node.
    #[error("edge {from} -> {to} crosses {produces} to {expects} with no crossing node")]
    ImplicitCrossing {
        /// Producer.
        from: Id,
        /// Consumer.
        to: Id,
        /// Domain the producer's output lives in.
        produces: Domain,
        /// Domain the consumer reads from.
        expects: Domain,
    },
    /// A crossing node that does not cross: same domain on both sides, or an
    /// unresolved [`Domain::Either`] endpoint.
    #[error("crossing {0} does not cross between two concrete domains")]
    DegenerateCrossing(Id),
    /// An asynchronous crossing with no in-flight bound.
    ///
    /// Unbounded readback eventually blocks the producer, which is a dropped
    /// frame reported as something else.
    #[error("crossing {0} is asynchronous and must declare maxInFlight > 0")]
    UnboundedCrossing(Id),
    /// A fixed rate that is zero or negative.
    #[error("node {0} declares a fixed rate that is not positive")]
    InvalidRate(Id),
    /// Committed a plan that was made against a different graph shape.
    #[error("plan is stale: the graph changed after it was made")]
    StalePlan,
}

struct DisplayPath<'a>(&'a [Id]);

impl std::fmt::Display for DisplayPath<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        for (i, id) in self.0.iter().enumerate() {
            if i > 0 {
                f.write_str(" -> ")?;
            }
            write!(f, "{id}")?;
        }
        Ok(())
    }
}

// ── the graph ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
struct NodeState {
    generation: Generation,
    /// A parameter on the node itself changed, or it has never cooked.
    self_dirty: bool,
    /// Bumped by every [`CookGraph::touch`].
    ///
    /// A plan records the count it saw, and a commit clears `self_dirty` only
    /// if the count still matches. Without it, an edit that lands *after* the
    /// node's inputs were sampled but *before* the scheduler reports — which is
    /// the entire window a parameter arrives in — is cleared by that same
    /// node's commit and never cooks. The same hazard `commit_cooked` exists to
    /// close, from the other side.
    touched: u64,
}

/// The cook graph.
///
/// Dense storage with an id index: everything inside works on slot indices so
/// the hot paths are array walks, and [`Id`] only appears at the boundary.
#[derive(Debug, Clone)]
pub struct CookGraph {
    nodes: Vec<Node>,
    state: Vec<NodeState>,
    slots: BTreeMap<Id, usize>,
    edges: Vec<EdgeRec>,
    composition_rate: Rational,
    /// Bumped on every structural change, so a plan cannot be committed against
    /// a graph it no longer describes.
    revision: u64,
}

impl CookGraph {
    /// An empty graph driven by `composition_rate`.
    ///
    /// The composition rate is the GPU domain's clock and the fallback for a
    /// node with nothing to inherit from.
    ///
    /// # Panics
    /// If `composition_rate` is not positive. [`CookGraph::add_node`] already
    /// refuses a [`Rate::Fixed`] that is zero or negative
    /// ([`GraphError::InvalidRate`]); this is the same rule applied to the one
    /// rate that is not attached to a node, and it matters more rather than
    /// less, because it is what every unresolved node falls back to. Left
    /// unchecked it does not fail — it quietly hands the scheduler a 0 Hz
    /// composition, or a *negative* period out of
    /// [`CookRate::period`]. Construction-time programmer error, refused the
    /// same way [`Rational::new`] refuses a zero denominator.
    #[must_use]
    pub fn new(composition_rate: Rational) -> Self {
        assert!(
            composition_rate.num() > 0,
            "composition rate must be positive, got {}/{}",
            composition_rate.num(),
            composition_rate.den()
        );
        Self {
            nodes: Vec::new(),
            state: Vec::new(),
            slots: BTreeMap::new(),
            edges: Vec::new(),
            composition_rate,
            revision: 0,
        }
    }

    /// The composition cadence this graph resolves [`Rate::Inherit`] against.
    #[must_use]
    pub const fn composition_rate(&self) -> Rational {
        self.composition_rate
    }

    /// Number of nodes.
    #[must_use]
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    /// Whether the graph has no nodes.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    /// Adds a node.
    ///
    /// Crossing invariants are checked here rather than at plan time so a patch
    /// cannot be saved in a state that only fails later.
    ///
    /// # Errors
    /// [`GraphError::DuplicateNode`], [`GraphError::DegenerateCrossing`],
    /// [`GraphError::UnboundedCrossing`], [`GraphError::InvalidRate`].
    pub fn add_node(&mut self, node: Node) -> Result<(), GraphError> {
        if self.slots.contains_key(&node.id) {
            return Err(GraphError::DuplicateNode(node.id));
        }
        if let Rate::Fixed(r) = node.rate {
            if r.num() <= 0 {
                return Err(GraphError::InvalidRate(node.id));
            }
        }
        if let NodeKind::Crossing { from, cost } = node.kind {
            let to = node.domain;
            if from == to || from == Domain::Either || to == Domain::Either {
                return Err(GraphError::DegenerateCrossing(node.id));
            }
            if is_asynchronous(from, to) && cost.max_in_flight == 0 {
                return Err(GraphError::UnboundedCrossing(node.id));
            }
        }
        self.slots.insert(node.id, self.nodes.len());
        self.nodes.push(node);
        self.state.push(NodeState {
            generation: Generation::NEVER,
            // Never cooked, so it owes its first cook unconditionally.
            self_dirty: true,
            touched: 0,
        });
        self.revision += 1;
        Ok(())
    }

    /// Connects `from` to `to` for this pass.
    ///
    /// # Errors
    /// [`GraphError::UnknownNode`] if either end is missing.
    pub fn connect(&mut self, from: Id, to: Id) -> Result<(), GraphError> {
        self.add_edge(from, to, EdgeTiming::Immediate)
    }

    /// Connects `from` to `to` with a one-pass delay: `to` reads the result
    /// `from` produced last pass.
    ///
    /// This is how feedback is expressed. It imposes no ordering constraint and
    /// is excluded from cycle detection, because the value it carries already
    /// exists when the pass begins — including when `from == to`, which is an
    /// ordinary single-node feedback buffer.
    ///
    /// # Errors
    /// [`GraphError::UnknownNode`] if either end is missing.
    pub fn connect_delayed(&mut self, from: Id, to: Id) -> Result<(), GraphError> {
        self.add_edge(from, to, EdgeTiming::Delayed)
    }

    fn add_edge(&mut self, from: Id, to: Id, timing: EdgeTiming) -> Result<(), GraphError> {
        let from = self.slot(from)?;
        let to = self.slot(to)?;
        self.edges.push(EdgeRec {
            from,
            to,
            timing,
            seen: Generation::NEVER,
        });
        self.revision += 1;
        Ok(())
    }

    /// The node with this id.
    #[must_use]
    pub fn node(&self, id: Id) -> Option<&Node> {
        self.slots.get(&id).map(|&i| &self.nodes[i])
    }

    /// Every node, in insertion order.
    pub fn nodes(&self) -> impl Iterator<Item = &Node> + '_ {
        self.nodes.iter()
    }

    /// Every edge, in insertion order.
    pub fn edges(&self) -> impl Iterator<Item = Edge> + '_ {
        self.edges.iter().map(|e| Edge {
            from: self.nodes[e.from].id,
            to: self.nodes[e.to].id,
            timing: e.timing,
        })
    }

    /// Current output generation of a node.
    #[must_use]
    pub fn generation(&self, id: Id) -> Option<Generation> {
        self.slots.get(&id).map(|&i| self.state[i].generation)
    }

    /// Marks a node's own parameters as changed, so it cooks next pass.
    ///
    /// Only the node itself — downstream dirtiness follows from the generation
    /// this node publishes when it cooks, which is what keeps a parameter edit
    /// from having to know what reads it.
    ///
    /// # Errors
    /// [`GraphError::UnknownNode`].
    pub fn touch(&mut self, id: Id) -> Result<(), GraphError> {
        let i = self.slot(id)?;
        self.state[i].self_dirty = true;
        self.state[i].touched = self.state[i].touched.wrapping_add(1);
        Ok(())
    }

    /// Topological cook order over immediate edges.
    ///
    /// # Errors
    /// [`GraphError::Cycle`] naming one concrete loop. Delayed edges are
    /// excluded, so feedback is not a cycle.
    pub fn order(&self) -> Result<Vec<Id>, GraphError> {
        let order = self.topological(&self.adjacency(), None)?;
        Ok(order.iter().map(|&i| self.nodes[i].id).collect())
    }

    /// Every domain crossing in the graph, with its resolved rate and cost.
    ///
    /// # Errors
    /// [`GraphError::Cycle`], [`GraphError::ImplicitCrossing`].
    pub fn crossings(&self) -> Result<Vec<CrossingReport>, GraphError> {
        let r = self.resolve(&self.adjacency())?;
        Ok(self.collect_crossings(&r))
    }

    /// Resolved placement of every node.
    ///
    /// # Errors
    /// [`GraphError::Cycle`], [`GraphError::ImplicitCrossing`].
    pub fn placements(&self) -> Result<BTreeMap<Id, Placement>, GraphError> {
        let r = self.resolve(&self.adjacency())?;
        Ok(self.placement_map(&r))
    }

    /// Works out what must cook this pass, in what order, in what batches.
    ///
    /// Mutates nothing: generations advance only in [`CookGraph::commit`], once
    /// the scheduler reports what actually ran.
    ///
    /// The plan says what is *stale*, not what is *due*. Rate gating is the
    /// scheduler's job — it has the tick, and a 44 Hz node simply is not
    /// dispatched on every 60 Hz pass even while it is stale.
    ///
    /// # Errors
    /// [`GraphError::Cycle`], [`GraphError::ImplicitCrossing`].
    pub fn plan(&self) -> Result<CookPlan, GraphError> {
        let adj = self.adjacency();
        let r = self.resolve(&adj)?;
        let placements: Vec<Placement> = (0..self.nodes.len())
            .map(|i| Placement {
                domain: r.domains[i],
                rate: r.rates[i],
            })
            .collect();

        // Re-ordered now that placement is known: among nodes whose
        // dependencies are all satisfied, prefer one that extends the current
        // batch. Still a valid topological order — it only chooses between
        // nodes that were already free to run — but it stops two independent
        // chains from interleaving into single-node batches.
        let order = self.topological(&adj, Some(&placements))?;

        let mut projected: Vec<Generation> = self.state.iter().map(|s| s.generation).collect();
        let mut cook = Vec::new();
        for &i in &order {
            if self.is_stale(i, &adj, &projected) {
                projected[i] = projected[i].next();
                cook.push(i);
            }
        }

        let batches = self.build_batches(&cook, &placements);
        Ok(CookPlan {
            order: order.iter().map(|&i| self.nodes[i].id).collect(),
            cook: cook.iter().map(|&i| self.nodes[i].id).collect(),
            batches,
            crossings: self.collect_crossings(&r),
            placements: self.placement_map(&r),
            touched: self.state.iter().map(|s| s.touched).collect(),
            revision: self.revision,
        })
    }

    /// Records that every node in `plan.cook` cooked.
    ///
    /// # Errors
    /// [`GraphError::StalePlan`] if the graph changed since the plan was made.
    pub fn commit(&mut self, plan: &CookPlan) -> Result<(), GraphError> {
        let cooked = plan.cook.clone();
        self.commit_cooked(plan, &cooked)
    }

    /// Records that only `cooked` — a subset of `plan.cook` — actually cooked.
    ///
    /// The partial form is the important one: work dropped to make a deadline
    /// must stay dirty, or the next pass presents a stale result as fresh. A
    /// consumer that cooked against a skipped producer correctly records the
    /// producer's *old* generation, so it re-cooks when the producer catches up.
    ///
    /// # Errors
    /// [`GraphError::StalePlan`], [`GraphError::UnknownNode`].
    pub fn commit_cooked(&mut self, plan: &CookPlan, cooked: &[Id]) -> Result<(), GraphError> {
        if plan.revision != self.revision {
            return Err(GraphError::StalePlan);
        }
        let mut done = BTreeSet::new();
        for &id in cooked {
            done.insert(self.slot(id)?);
        }

        let committed: Vec<Generation> = self.state.iter().map(|s| s.generation).collect();
        let projected: Vec<Generation> = (0..self.nodes.len())
            .map(|i| {
                if done.contains(&i) {
                    committed[i].next()
                } else {
                    committed[i]
                }
            })
            .collect();

        for e in &mut self.edges {
            if !done.contains(&e.to) {
                continue;
            }
            e.seen = match e.timing {
                // The consumer saw this pass's result.
                EdgeTiming::Immediate => projected[e.from],
                // The consumer saw last pass's result, which is what the
                // producer's generation still holds until it cooks again.
                EdgeTiming::Delayed => committed[e.from],
            };
        }
        for &i in &done {
            self.state[i].generation = projected[i];
            // Only if nothing touched this node after the plan sampled it;
            // otherwise the cook that just finished used the old parameter and
            // clearing here would discard the new one for good.
            if self.state[i].touched == plan.touched[i] {
                self.state[i].self_dirty = false;
            }
        }
        Ok(())
    }

    // ── internals ────────────────────────────────────────────────────────────

    fn slot(&self, id: Id) -> Result<usize, GraphError> {
        self.slots.get(&id).copied().ok_or(GraphError::UnknownNode(id))
    }

    /// Edge indices into and out of each node.
    ///
    /// Built once per pass and threaded through resolution, ordering and the
    /// dirty walk: `plan` runs on the frame clock, so neither it nor anything
    /// it calls may scan the whole edge list per node.
    fn adjacency(&self) -> Adjacency {
        let n = self.nodes.len();
        let mut adj = Adjacency {
            into: vec![Vec::new(); n],
            outof: vec![Vec::new(); n],
        };
        for (i, e) in self.edges.iter().enumerate() {
            adj.into[e.to].push(i);
            adj.outof[e.from].push(i);
        }
        adj
    }

    /// Kahn's algorithm over immediate edges.
    ///
    /// With `placements`, ties between ready nodes are broken in favour of
    /// staying in the current batch.
    fn topological(
        &self,
        adj: &Adjacency,
        placements: Option<&[Placement]>,
    ) -> Result<Vec<usize>, GraphError> {
        let n = self.nodes.len();
        let mut indegree: Vec<usize> = (0..n)
            .map(|i| {
                adj.into[i]
                    .iter()
                    .filter(|&&e| self.edges[e].timing == EdgeTiming::Immediate)
                    .count()
            })
            .collect();

        let mut ready: Vec<usize> = (0..n).filter(|&i| indegree[i] == 0).collect();
        let mut out = Vec::with_capacity(n);
        let mut current: Option<(Domain, CookRate)> = None;

        while !ready.is_empty() {
            let pick = match (placements, current) {
                (Some(p), Some(key)) => ready
                    .iter()
                    .position(|&i| (p[i].domain, p[i].rate) == key)
                    .unwrap_or(0),
                // No placement information, or nothing emitted yet: insertion
                // order, which keeps the order reproducible run to run.
                _ => 0,
            };
            let i = ready.remove(pick);
            if let Some(p) = placements {
                current = Some((p[i].domain, p[i].rate));
            }
            out.push(i);

            for &e in &adj.outof[i] {
                let edge = self.edges[e];
                if edge.timing != EdgeTiming::Immediate {
                    continue;
                }
                indegree[edge.to] -= 1;
                if indegree[edge.to] == 0 {
                    ready.push(edge.to);
                }
            }
        }

        if out.len() != n {
            let emitted: BTreeSet<usize> = out.into_iter().collect();
            let stuck: BTreeSet<usize> = (0..n).filter(|i| !emitted.contains(i)).collect();
            return Err(GraphError::Cycle {
                nodes: self.extract_cycle(&stuck, adj),
            });
        }
        Ok(out)
    }

    /// Names one concrete loop out of the nodes Kahn could not emit.
    ///
    /// Walks *backwards*: every stuck node has at least one producer that is
    /// also stuck (that is exactly why its in-degree never reached zero), so a
    /// backwards walk can never dead-end and must revisit a node within
    /// `stuck.len()` steps. A forwards walk can wander into the tail hanging
    /// off the loop and stop with nothing to report.
    fn extract_cycle(&self, stuck: &BTreeSet<usize>, adj: &Adjacency) -> Vec<Id> {
        let Some(&start) = stuck.iter().next() else {
            return Vec::new();
        };
        let mut path = vec![start];
        let mut seen_at = BTreeMap::from([(start, 0usize)]);
        let mut cursor = start;

        loop {
            let producer = adj.into[cursor]
                .iter()
                .map(|&e| self.edges[e])
                .find(|e| e.timing == EdgeTiming::Immediate && stuck.contains(&e.from))
                .map(|e| e.from);
            let Some(producer) = producer else {
                return path.iter().rev().map(|&i| self.nodes[i].id).collect();
            };
            if let Some(&at) = seen_at.get(&producer) {
                // path[j + 1] feeds path[j], so reversing the tail puts the
                // loop back into edge order.
                return path[at..].iter().rev().map(|&i| self.nodes[i].id).collect();
            }
            seen_at.insert(producer, path.len());
            path.push(producer);
            cursor = producer;
        }
    }

    fn resolve(&self, adj: &Adjacency) -> Result<Resolution, GraphError> {
        let order = self.topological(adj, None)?;
        let domains = self.resolve_domains(adj, &order)?;
        let rates = self.resolve_rates(adj, &order, &domains);
        Ok(Resolution {
            domains,
            rates,
            order,
        })
    }

    /// Resolves [`Domain::Either`] and rejects implicit crossings.
    fn resolve_domains(&self, adj: &Adjacency, order: &[usize]) -> Result<Vec<Domain>, GraphError> {
        let mut domain: Vec<Option<Domain>> = self
            .nodes
            .iter()
            .map(|node| (node.domain != Domain::Either).then_some(node.domain))
            .collect();

        // Both sweeps repeat until a round decides nothing new.
        //
        // One sweep each way is not enough, and the reason is the same one
        // `resolve_rates` documents — except rates escape it by ignoring
        // delayed edges, and domains cannot: a delayed edge still moves data,
        // so its two ends must agree on a domain or it is an implicit
        // crossing. `order` is topological over *immediate* edges only, so a
        // delayed edge may run backwards through it in either direction, and a
        // node whose only decided neighbour sits on the far side of one is
        // skipped by both sweeps and falls through to the `Cpu` default below.
        // Which nodes that hit depended on insertion order, so the same patch
        // resolved cleanly or failed as [`GraphError::ImplicitCrossing`]
        // purely according to the order its layers happened to be added in —
        // see `domain_resolution_does_not_depend_on_node_insertion_order`.
        //
        // Terminating: a slot only ever goes `None` -> `Some` and never
        // changes again, so a round that progresses decides at least one more
        // of a finite number of nodes. In practice every graph without an
        // Either node stops after one round.
        loop {
            let mut progressed = false;

            // Forwards: an undecided node goes wherever its first decided
            // producer already is, so it joins that batch instead of forcing a
            // crossing. Conflicting producers are left to the validation pass
            // below, which can name the offending edge.
            for &i in order {
                if domain[i].is_some() {
                    continue;
                }
                if let Some(d) = adj.into[i].iter().find_map(|&e| domain[self.edges[e].from]) {
                    domain[i] = Some(d);
                    progressed = true;
                }
            }

            // Backwards: a node with no decided producer — a root constant, or
            // one fed only by other undecided nodes — follows its consumers
            // instead.
            for &i in order.iter().rev() {
                if domain[i].is_some() {
                    continue;
                }
                let decided = adj.outof[i].iter().find_map(|&e| {
                    let consumer = self.edges[e].to;
                    match self.nodes[consumer].kind {
                        NodeKind::Crossing { from, .. } => Some(from),
                        NodeKind::Op => domain[consumer],
                    }
                });
                if let Some(d) = decided {
                    domain[i] = Some(d);
                    progressed = true;
                }
            }

            if !progressed {
                break;
            }
        }

        // Anything still undecided touches nothing that cares. CPU is the
        // cheaper guess: it needs no texture allocation.
        let domain: Vec<Domain> = domain.into_iter().map(|d| d.unwrap_or(Domain::Cpu)).collect();

        for e in &self.edges {
            let produces = domain[e.from];
            let expects = match self.nodes[e.to].kind {
                NodeKind::Crossing { from, .. } => from,
                NodeKind::Op => domain[e.to],
            };
            if produces != expects {
                return Err(GraphError::ImplicitCrossing {
                    from: self.nodes[e.from].id,
                    to: self.nodes[e.to].id,
                    produces,
                    expects,
                });
            }
        }
        Ok(domain)
    }

    /// Resolves [`Rate::Inherit`].
    ///
    /// Two passes in opposite directions, because inheritance has two sources.
    /// Ordinary work takes its cadence from upstream — it cannot usefully cook
    /// faster than what feeds it. A crossing takes its cadence from
    /// *downstream*: a readback exists to serve a consumer, and a 60 Hz
    /// composition read at 60 Hz for a 44 Hz DMX sink buys nothing but copies.
    fn resolve_rates(
        &self,
        adj: &Adjacency,
        order: &[usize],
        domains: &[Domain],
    ) -> Vec<CookRate> {
        let mut rate: Vec<Option<CookRate>> = vec![None; self.nodes.len()];

        for &i in order {
            let node = &self.nodes[i];
            rate[i] = match node.rate {
                Rate::Fixed(r) => Some(CookRate::Periodic(r)),
                Rate::OnChange => Some(CookRate::OnChange),
                // Deferred to the backwards pass: a crossing is defined by the
                // consumer it serves.
                Rate::Inherit if node.is_crossing() => None,
                Rate::Inherit => {
                    // Delayed edges deliberately excluded: last pass's data
                    // says nothing about how often this node must run, and
                    // letting feedback drive cadence makes the resolution
                    // itself circular.
                    let inherited = adj.into[i]
                        .iter()
                        .map(|&e| self.edges[e])
                        .filter(|e| e.timing == EdgeTiming::Immediate)
                        .filter_map(|e| rate[e.from])
                        .reduce(faster);
                    match inherited {
                        Some(r) => Some(r),
                        // The composition clock *is* the GPU clock, so a GPU
                        // node with nothing upstream takes it rather than
                        // waiting to be told by a downstream sink.
                        None if domains[i] == Domain::Gpu => {
                            Some(CookRate::Periodic(self.composition_rate))
                        }
                        None => None,
                    }
                }
            };
        }

        for &i in order.iter().rev() {
            if rate[i].is_some() {
                continue;
            }
            // Immediate only, for the same two reasons as the forwards pass.
            // The second one bites harder here: the reverse walk is only
            // order-correct over immediate edges, so a delayed consumer may not
            // have been resolved yet when its producer asks — which made the
            // answer depend on node insertion order rather than on the graph.
            rate[i] = adj.outof[i]
                .iter()
                .map(|&e| self.edges[e])
                .filter(|e| e.timing == EdgeTiming::Immediate)
                .filter_map(|e| rate[e.to])
                .reduce(faster);
        }

        rate.into_iter()
            .map(|r| r.unwrap_or(CookRate::Periodic(self.composition_rate)))
            .collect()
    }

    /// Whether a node must cook this pass, given the generations its producers
    /// will publish.
    fn is_stale(&self, i: usize, adj: &Adjacency, projected: &[Generation]) -> bool {
        if self.state[i].self_dirty || self.nodes[i].time_dependent {
            return true;
        }
        adj.into[i].iter().any(|&e| {
            let e = self.edges[e];
            match e.timing {
                EdgeTiming::Immediate => projected[e.from] > e.seen,
                // Feedback compares against the committed generation: the
                // producer's current output *is* last pass's result until it
                // cooks again, later in this same order.
                EdgeTiming::Delayed => self.state[e.from].generation > e.seen,
            }
        })
    }

    fn build_batches(&self, cook: &[usize], placements: &[Placement]) -> Vec<Batch> {
        let mut batches: Vec<Batch> = Vec::new();
        for &i in cook {
            let p = placements[i];
            let kind = if self.nodes[i].is_crossing() {
                BatchKind::Crossing
            } else {
                BatchKind::Work
            };
            let extends = batches.last().is_some_and(|b| {
                // A crossing is dispatched differently from ordinary work —
                // asynchronously, against an in-flight bound — so it is never
                // folded into a batch the scheduler would submit as one unit.
                kind == BatchKind::Work
                    && b.kind == BatchKind::Work
                    && b.domain == p.domain
                    && b.rate == p.rate
            });
            if extends {
                batches
                    .last_mut()
                    .expect("extends implies a last batch")
                    .nodes
                    .push(self.nodes[i].id);
            } else {
                batches.push(Batch {
                    domain: p.domain,
                    rate: p.rate,
                    kind,
                    nodes: vec![self.nodes[i].id],
                });
            }
        }
        batches
    }

    fn collect_crossings(&self, r: &Resolution) -> Vec<CrossingReport> {
        r.order
            .iter()
            .filter_map(|&i| match self.nodes[i].kind {
                NodeKind::Crossing { from, cost } => Some(CrossingReport {
                    node: self.nodes[i].id,
                    from,
                    to: r.domains[i],
                    rate: r.rates[i],
                    cost,
                }),
                NodeKind::Op => None,
            })
            .collect()
    }

    fn placement_map(&self, r: &Resolution) -> BTreeMap<Id, Placement> {
        self.nodes
            .iter()
            .enumerate()
            .map(|(i, node)| {
                (
                    node.id,
                    Placement {
                        domain: r.domains[i],
                        rate: r.rates[i],
                    },
                )
            })
            .collect()
    }
}

struct Resolution {
    domains: Vec<Domain>,
    rates: Vec<CookRate>,
    order: Vec<usize>,
}

/// Edge indices into and out of each node, by slot.
struct Adjacency {
    into: Vec<Vec<usize>>,
    outof: Vec<Vec<usize>>,
}

/// A GPU to CPU transfer must be asynchronous: the CPU asking the GPU to stop
/// and hand something over is a pipeline bubble measured in frames. The reverse
/// is an upload, which the queue already absorbs.
const fn is_asynchronous(from: Domain, to: Domain) -> bool {
    matches!((from, to), (Domain::Gpu, Domain::Cpu))
}

/// The cadence that satisfies both: a node fed at two rates must keep up with
/// the faster one, and a periodic input always outranks an event-driven one.
fn faster(a: CookRate, b: CookRate) -> CookRate {
    match (a, b) {
        (CookRate::Periodic(x), CookRate::Periodic(y)) => {
            // Cross-multiply in i128 rather than compare floats: 30000/1001 and
            // 29.97 are not the same number and this must not pretend they are.
            let faster = i128::from(x.num()) * i128::from(y.den())
                >= i128::from(y.num()) * i128::from(x.den());
            CookRate::Periodic(if faster { x } else { y })
        }
        (CookRate::Periodic(x), CookRate::OnChange) => CookRate::Periodic(x),
        (CookRate::OnChange, CookRate::Periodic(y)) => CookRate::Periodic(y),
        (CookRate::OnChange, CookRate::OnChange) => CookRate::OnChange,
    }
}

// ── the plan ─────────────────────────────────────────────────────────────────

/// How a batch is dispatched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatchKind {
    /// Ordinary work, submitted as one unit.
    Work,
    /// A single domain crossing, issued asynchronously against its in-flight
    /// bound and never merged with ordinary work.
    Crossing,
}

/// A run of nodes the scheduler can dispatch together.
///
/// Contiguous in the cook order and uniform in `(domain, rate)` — the two
/// things that decide *which* queue the work goes to and *when*.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    /// Domain every node in the batch runs in. Never [`Domain::Either`].
    pub domain: Domain,
    /// Cadence every node in the batch runs at.
    pub rate: CookRate,
    /// Work, or a lone crossing.
    pub kind: BatchKind,
    /// Members, in cook order.
    pub nodes: Vec<Id>,
}

/// One domain crossing, resolved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CrossingReport {
    /// The crossing node.
    pub node: Id,
    /// Domain data is read from.
    pub from: Domain,
    /// Domain data lands in.
    pub to: Domain,
    /// Resolved cadence — the consumer's, not the producer's.
    pub rate: CookRate,
    /// Declared size and in-flight bound.
    pub cost: CrossingCost,
}

impl CrossingReport {
    /// Whether this crossing must be issued asynchronously.
    #[must_use]
    pub const fn is_asynchronous(&self) -> bool {
        is_asynchronous(self.from, self.to)
    }

    /// Sustained transfer rate this crossing asks for, in bytes per second.
    ///
    /// Lossy on purpose: this is a budgeting figure, compared against bus
    /// bandwidth, never accumulated into a timestamp.
    #[must_use]
    pub fn bytes_per_second(&self) -> f64 {
        match self.rate.hz() {
            Some(hz) => self.cost.bytes as f64 * hz,
            None => 0.0,
        }
    }

    /// Worst-case age of a result when the consumer reads it, exactly.
    ///
    /// `max_in_flight` cooks at the crossing's own rate. `None` for an
    /// event-driven crossing, which has no cadence to measure against.
    #[must_use]
    pub fn worst_case_latency(&self) -> Option<Rational> {
        match self.rate {
            CookRate::Periodic(r) if r.num() > 0 => Some(Rational::new(
                i64::from(self.cost.max_in_flight) * r.den(),
                r.num(),
            )),
            _ => None,
        }
    }
}

/// What to cook this pass, where, and in what order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CookPlan {
    /// Every node, in a topological order chosen to maximise batching.
    pub order: Vec<Id>,
    /// The stale subset of [`CookPlan::order`], in the same relative order.
    pub cook: Vec<Id>,
    /// [`CookPlan::cook`], partitioned into dispatchable runs.
    pub batches: Vec<Batch>,
    /// Every domain crossing in the graph, whether or not it cooks this pass.
    pub crossings: Vec<CrossingReport>,
    placements: BTreeMap<Id, Placement>,
    /// `touched` count per slot when the plan was made. Slot-indexed, which
    /// `revision` makes sound: every structural change bumps it, and a plan
    /// whose revision no longer matches is refused before this is read.
    touched: Vec<u64>,
    revision: u64,
}

impl CookPlan {
    /// Resolved placement of a node.
    #[must_use]
    pub fn placement(&self, id: Id) -> Option<Placement> {
        self.placements.get(&id).copied()
    }

    /// Whether this node is stale this pass. Linear in the cook list.
    #[must_use]
    pub fn will_cook(&self, id: Id) -> bool {
        self.cook.contains(&id)
    }

    /// Sustained bytes per second across every crossing in the graph.
    ///
    /// The number "no CPU readback ever" was trying to protect, made visible
    /// instead of forbidden.
    #[must_use]
    pub fn crossing_bytes_per_second(&self) -> f64 {
        self.crossings.iter().map(CrossingReport::bytes_per_second).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::doc::IdAllocator;

    /// DMX512's wire rate: ~44 Hz, and no faster whatever the GPU is doing.
    /// The whole reason a second cadence exists.
    fn dmx() -> Rational {
        Rational::new(44, 1)
    }

    /// Small fixture builder — keeps the tests about graph behaviour rather
    /// than about id bookkeeping.
    struct Fix {
        g: CookGraph,
        ids: IdAllocator,
    }

    impl Fix {
        fn new() -> Self {
            Self {
                g: CookGraph::new(Rational::FPS_60),
                ids: IdAllocator::new(),
            }
        }

        fn add(&mut self, domain: Domain, rate: Rate) -> Id {
            let id = self.ids.alloc();
            self.g.add_node(Node::op(id, domain, rate)).expect("add");
            id
        }

        fn gpu(&mut self) -> Id {
            self.add(Domain::Gpu, Rate::Inherit)
        }

        fn cpu(&mut self, rate: Rate) -> Id {
            self.add(Domain::Cpu, rate)
        }

        fn video(&mut self) -> Id {
            let id = self.ids.alloc();
            self.g
                .add_node(Node::op(id, Domain::Gpu, Rate::Inherit).driven_by_time())
                .expect("add");
            id
        }

        fn readback(&mut self, bytes: u64, in_flight: u32) -> Id {
            let id = self.ids.alloc();
            self.g
                .add_node(Node::crossing(
                    id,
                    Domain::Gpu,
                    Domain::Cpu,
                    CrossingCost::new(bytes, in_flight),
                ))
                .expect("add");
            id
        }

        fn link(&mut self, from: Id, to: Id) {
            self.g.connect(from, to).expect("connect");
        }

        fn pass(&mut self) -> CookPlan {
            let plan = self.g.plan().expect("plan");
            self.g.commit(&plan).expect("commit");
            plan
        }
    }

    fn position(order: &[Id], id: Id) -> usize {
        order.iter().position(|&x| x == id).expect("in order")
    }

    // ── ordering ─────────────────────────────────────────────────────────────

    #[test]
    fn topological_order_places_every_producer_before_its_consumer() {
        let mut f = Fix::new();
        // Diamond with a long tail: a: ->b,c ; b,c -> d -> e
        let (a, b, c, d, e) = (f.gpu(), f.gpu(), f.gpu(), f.gpu(), f.gpu());
        f.link(a, b);
        f.link(a, c);
        f.link(b, d);
        f.link(c, d);
        f.link(d, e);

        let order = f.g.order().expect("order");
        assert_eq!(order.len(), 5);
        for edge in f.g.edges() {
            assert!(
                position(&order, edge.from) < position(&order, edge.to),
                "{} must precede {}",
                edge.from,
                edge.to
            );
        }
    }

    #[test]
    fn a_cycle_is_rejected_and_names_the_loop() {
        let mut f = Fix::new();
        let (a, b, c, tail) = (f.gpu(), f.gpu(), f.gpu(), f.gpu());
        f.link(a, b);
        f.link(b, c);
        f.link(c, a);
        // Hangs off the loop: must not be mistaken for part of it.
        f.link(c, tail);

        let err = f.g.order().expect_err("cycle must be rejected");
        let GraphError::Cycle { nodes } = err else {
            panic!("expected a cycle, got {err:?}");
        };
        assert_eq!(nodes.len(), 3, "the tail is not part of the loop: {nodes:?}");
        for id in [a, b, c] {
            assert!(nodes.contains(&id), "{id} is in the loop but not reported");
        }
    }

    #[test]
    fn an_immediate_self_edge_is_a_cycle() {
        let mut f = Fix::new();
        let a = f.gpu();
        f.link(a, a);
        assert_eq!(
            f.g.order(),
            Err(GraphError::Cycle { nodes: vec![a] }),
            "reading your own current frame has no fixed point"
        );
    }

    #[test]
    fn a_delayed_self_edge_is_feedback_not_a_cycle() {
        let mut f = Fix::new();
        let a = f.gpu();
        f.g.connect_delayed(a, a).expect("connect");
        assert_eq!(f.g.order().expect("order"), vec![a]);
    }

    #[test]
    fn feedback_does_not_constrain_cook_order() {
        let mut f = Fix::new();
        let (src, mix, trail) = (f.gpu(), f.gpu(), f.gpu());
        f.link(src, mix);
        f.link(mix, trail);
        // Classic trails: the mix reads last frame's trail buffer.
        f.g.connect_delayed(trail, mix).expect("connect");

        let order = f.g.order().expect("feedback is not a cycle");
        assert!(position(&order, src) < position(&order, mix));
        assert!(position(&order, mix) < position(&order, trail));
    }

    // ── dirty generations ────────────────────────────────────────────────────

    #[test]
    fn a_fresh_graph_cooks_everything_once_then_goes_quiet() {
        let mut f = Fix::new();
        let (a, b) = (f.gpu(), f.gpu());
        f.link(a, b);

        let first = f.pass();
        assert_eq!(first.cook.len(), 2, "nothing has ever cooked");
        assert_eq!(f.g.generation(a), Some(Generation(1)));

        let second = f.g.plan().expect("plan");
        assert!(
            second.cook.is_empty(),
            "nothing changed, so nothing re-cooks: {:?}",
            second.cook
        );
    }

    #[test]
    fn a_change_propagates_through_every_level() {
        let mut f = Fix::new();
        let chain: Vec<Id> = (0..5).map(|_| f.gpu()).collect();
        for w in chain.windows(2) {
            f.link(w[0], w[1]);
        }
        f.pass();
        assert!(f.g.plan().expect("plan").cook.is_empty());

        f.g.touch(chain[0]).expect("touch");
        let plan = f.pass();
        assert_eq!(plan.cook, chain, "a root edit must reach the far end");
        for id in &chain {
            assert_eq!(f.g.generation(*id), Some(Generation(2)));
        }
    }

    #[test]
    fn a_node_cooks_once_per_pass_however_many_paths_reach_it() {
        let mut f = Fix::new();
        let (a, b, c, d) = (f.gpu(), f.gpu(), f.gpu(), f.gpu());
        f.link(a, b);
        f.link(a, c);
        f.link(b, d);
        f.link(c, d);
        f.pass();

        f.g.touch(a).expect("touch");
        let plan = f.g.plan().expect("plan");
        assert_eq!(plan.cook.len(), 4);
        assert_eq!(
            plan.cook.iter().filter(|&&x| x == d).count(),
            1,
            "both diamond arms reach d; it still cooks once"
        );
    }

    #[test]
    fn a_slow_moving_input_is_not_masked_by_a_fast_one() {
        // The reason dirtiness is tracked per edge rather than as one
        // high-water mark per node: `slow` is several generations behind
        // `fast`, so a single max() watermark would swallow its change.
        let mut f = Fix::new();
        let (fast, slow, mix) = (f.gpu(), f.gpu(), f.gpu());
        f.link(fast, mix);
        f.link(slow, mix);
        f.pass();

        for _ in 0..3 {
            f.g.touch(fast).expect("touch");
            f.pass();
        }
        assert!(f.g.generation(fast) > f.g.generation(slow));

        f.g.touch(slow).expect("touch");
        let plan = f.g.plan().expect("plan");
        assert!(
            plan.will_cook(mix),
            "mix must re-cook: its slow input moved, even though its fast input is higher"
        );
    }

    #[test]
    fn a_video_source_is_dirty_every_pass_but_a_still_is_not() {
        let mut f = Fix::new();
        let video = f.video();
        let still = f.gpu();
        let (from_video, from_still) = (f.gpu(), f.gpu());
        f.link(video, from_video);
        f.link(still, from_still);
        f.pass();

        for pass in 0..3 {
            let plan = f.g.plan().expect("plan");
            assert!(
                plan.will_cook(video) && plan.will_cook(from_video),
                "pass {pass}: a near-static video still decodes and advances its timestamp"
            );
            assert!(
                !plan.will_cook(still) && !plan.will_cook(from_still),
                "pass {pass}: a still image with unchanged inputs must stay clean"
            );
            f.g.commit(&plan).expect("commit");
        }
    }

    #[test]
    fn feedback_keeps_a_loop_cooking_even_with_a_static_source() {
        let mut f = Fix::new();
        let (src, mix, trail) = (f.gpu(), f.gpu(), f.gpu());
        f.link(src, mix);
        f.link(mix, trail);
        f.g.connect_delayed(trail, mix).expect("connect");
        f.pass();

        for pass in 0..4 {
            let plan = f.g.plan().expect("plan");
            assert!(
                plan.will_cook(mix) && plan.will_cook(trail),
                "pass {pass}: a feedback buffer evolves every frame by definition"
            );
            assert!(
                !plan.will_cook(src),
                "pass {pass}: the static source itself is still clean"
            );
            f.g.commit(&plan).expect("commit");
        }
    }

    #[test]
    fn work_dropped_for_a_deadline_stays_dirty() {
        let mut f = Fix::new();
        let (a, b) = (f.gpu(), f.gpu());
        f.link(a, b);
        let plan = f.g.plan().expect("plan");
        // Scheduler ran out of frame: `b` was planned but never dispatched.
        f.g.commit_cooked(&plan, &[a]).expect("commit");

        let next = f.g.plan().expect("plan");
        assert!(!next.will_cook(a), "a already cooked");
        assert!(next.will_cook(b), "b never ran; it must not be marked clean");

        f.g.commit(&next).expect("commit");
        assert!(f.g.plan().expect("plan").cook.is_empty());
    }

    #[test]
    fn a_consumer_of_skipped_work_re_cooks_when_the_producer_catches_up() {
        let mut f = Fix::new();
        let (a, b) = (f.gpu(), f.gpu());
        f.link(a, b);
        let plan = f.g.plan().expect("plan");
        // Out of order: `b` ran, `a` was dropped. `b`'s result is built on an
        // input that has not been produced yet.
        f.g.commit_cooked(&plan, &[b]).expect("commit");

        let next = f.g.plan().expect("plan");
        assert!(next.will_cook(a), "a never ran");
        assert!(
            next.will_cook(b),
            "b must not be left holding a result it cooked against an input that had not run"
        );
        f.g.commit(&next).expect("commit");
        assert!(f.g.plan().expect("plan").cook.is_empty(), "now settled");
    }

    #[test]
    fn a_plan_made_before_an_edit_cannot_be_committed() {
        let mut f = Fix::new();
        let a = f.gpu();
        let plan = f.g.plan().expect("plan");
        let _ = f.gpu();
        assert_eq!(f.g.commit(&plan), Err(GraphError::StalePlan));
        assert_eq!(
            f.g.generation(a),
            Some(Generation::NEVER),
            "a rejected commit must not have advanced anything"
        );
    }

    // ── domains and crossings ────────────────────────────────────────────────

    #[test]
    fn an_implicit_domain_crossing_is_rejected() {
        let mut f = Fix::new();
        let gpu = f.gpu();
        let cpu = f.cpu(Rate::Fixed(dmx()));
        f.link(gpu, cpu);

        assert_eq!(
            f.g.plan().expect_err("must reject"),
            GraphError::ImplicitCrossing {
                from: gpu,
                to: cpu,
                produces: Domain::Gpu,
                expects: Domain::Cpu,
            }
        );
    }

    #[test]
    fn an_explicit_crossing_makes_the_same_graph_legal_and_is_reported() {
        let mut f = Fix::new();
        let gpu = f.gpu();
        let back = f.readback(1920 * 1080 * 4, 2);
        let cpu = f.cpu(Rate::Fixed(dmx()));
        f.link(gpu, back);
        f.link(back, cpu);

        let crossings = f.g.crossings().expect("legal graph");
        assert_eq!(crossings.len(), 1);
        let c = crossings[0];
        assert_eq!((c.node, c.from, c.to), (back, Domain::Gpu, Domain::Cpu));
        assert!(c.is_asynchronous(), "GPU to CPU must never be synchronous");
    }

    #[test]
    fn a_readback_runs_at_the_consumer_rate_not_the_producer_rate() {
        // The scenario the whole two-rate model exists for: a 60 Hz composition
        // driving a 44 Hz DMX universe.
        let mut f = Fix::new();
        let src = f.video();
        let effect = f.gpu();
        let back = f.readback(64 * 64 * 4, 2);
        let analyse = f.cpu(Rate::Inherit);
        let sink = f.cpu(Rate::Fixed(dmx()));
        f.link(src, effect);
        f.link(effect, back);
        f.link(back, analyse);
        f.link(analyse, sink);

        let p = f.g.placements().expect("legal graph");
        let rate = |id: Id| p[&id].rate;
        assert_eq!(rate(src), CookRate::Periodic(Rational::FPS_60));
        assert_eq!(rate(effect), CookRate::Periodic(Rational::FPS_60));
        assert_eq!(
            rate(back),
            CookRate::Periodic(dmx()),
            "reading a 60 Hz composition 60 times a second for a 44 Hz sink is pure copying"
        );
        assert_eq!(
            rate(analyse),
            CookRate::Periodic(dmx()),
            "a CPU chain with nothing periodic upstream follows the sink it feeds"
        );
    }

    #[test]
    fn crossing_cost_is_counted_not_assumed_free() {
        let mut f = Fix::new();
        let gpu = f.gpu();
        let bytes = 1920 * 1080 * 4;
        let back = f.readback(bytes, 3);
        let sink = f.cpu(Rate::Fixed(Rational::new(30, 1)));
        f.link(gpu, back);
        f.link(back, sink);

        let plan = f.g.plan().expect("plan");
        let c = plan.crossings[0];
        assert_eq!(c.rate, CookRate::Periodic(Rational::new(30, 1)));
        let expected = bytes as f64 * 30.0;
        assert!((plan.crossing_bytes_per_second() - expected).abs() < 1.0);
        assert!(
            plan.crossing_bytes_per_second() > 200e6,
            "a full-frame readback at 30 Hz is a quarter of a gigabyte a second; \
             the operator must be able to see that"
        );
        assert_eq!(
            c.worst_case_latency(),
            Some(Rational::new(3, 30)),
            "three in flight at 30 Hz is 100 ms of age"
        );
    }

    #[test]
    fn an_unbounded_asynchronous_crossing_is_rejected() {
        let mut g = CookGraph::new(Rational::FPS_60);
        let id = Id::new(1);
        assert_eq!(
            g.add_node(Node::crossing(
                id,
                Domain::Gpu,
                Domain::Cpu,
                CrossingCost::new(1024, 0)
            )),
            Err(GraphError::UnboundedCrossing(id))
        );
    }

    #[test]
    fn a_crossing_that_does_not_cross_is_rejected() {
        let mut g = CookGraph::new(Rational::FPS_60);
        for (raw, from, to) in [
            (1, Domain::Gpu, Domain::Gpu),
            (2, Domain::Either, Domain::Cpu),
            (3, Domain::Gpu, Domain::Either),
        ] {
            let id = Id::new(raw);
            assert_eq!(
                g.add_node(Node::crossing(id, from, to, CrossingCost::new(1, 1))),
                Err(GraphError::DegenerateCrossing(id)),
                "{from} to {to} is not a crossing"
            );
        }
    }

    #[test]
    fn an_either_node_joins_its_producers_domain() {
        let mut f = Fix::new();
        let gpu = f.gpu();
        let either = f.add(Domain::Either, Rate::Inherit);
        f.link(gpu, either);

        let p = f.g.placements().expect("legal graph");
        assert_eq!(
            p[&either].domain,
            Domain::Gpu,
            "placing it anywhere else would invent a crossing"
        );
    }

    #[test]
    fn an_either_root_follows_the_consumer_it_feeds() {
        let mut f = Fix::new();
        let either = f.add(Domain::Either, Rate::Inherit);
        let cpu = f.cpu(Rate::Fixed(dmx()));
        f.link(either, cpu);

        let p = f.g.placements().expect("legal graph");
        assert_eq!(p[&either].domain, Domain::Cpu);
        assert_eq!(p[&either].rate, CookRate::Periodic(dmx()));
    }

    #[test]
    fn an_either_node_pulled_both_ways_is_an_implicit_crossing() {
        let mut f = Fix::new();
        let gpu = f.gpu();
        let cpu = f.cpu(Rate::Fixed(dmx()));
        let either = f.add(Domain::Either, Rate::Inherit);
        f.link(gpu, either);
        f.link(cpu, either);

        // It cannot run in both domains at once; one of those edges crosses.
        assert!(matches!(
            f.g.plan().expect_err("must reject"),
            GraphError::ImplicitCrossing { .. }
        ));
    }

    // ── rates ────────────────────────────────────────────────────────────────

    #[test]
    fn inherit_takes_the_fastest_input() {
        let mut f = Fix::new();
        let slow = f.cpu(Rate::Fixed(Rational::new(30, 1)));
        let fast = f.cpu(Rate::Fixed(Rational::new(44, 1)));
        let mix = f.cpu(Rate::Inherit);
        f.link(slow, mix);
        f.link(fast, mix);

        let p = f.g.placements().expect("legal graph");
        assert_eq!(
            p[&mix].rate,
            CookRate::Periodic(Rational::new(44, 1)),
            "cooking at 30 would drop every other update from the 44 Hz input"
        );
    }

    #[test]
    fn an_on_change_input_does_not_slow_a_periodic_one() {
        let mut f = Fix::new();
        let event = f.cpu(Rate::OnChange);
        let clocked = f.cpu(Rate::Fixed(dmx()));
        let mix = f.cpu(Rate::Inherit);
        f.link(event, mix);
        f.link(clocked, mix);

        let p = f.g.placements().expect("legal graph");
        assert_eq!(p[&mix].rate, CookRate::Periodic(dmx()));
    }

    #[test]
    fn a_purely_event_driven_chain_stays_event_driven() {
        let mut f = Fix::new();
        let midi = f.cpu(Rate::OnChange);
        let map = f.cpu(Rate::Inherit);
        f.link(midi, map);

        let p = f.g.placements().expect("legal graph");
        assert_eq!(
            p[&map].rate,
            CookRate::OnChange,
            "nothing clocks this chain; polling it 60 times a second is waste"
        );
        assert_eq!(p[&map].rate.hz(), None);
        assert_eq!(p[&midi].rate.period(), None);
    }

    #[test]
    fn a_gpu_root_takes_the_composition_rate() {
        let mut g = CookGraph::new(Rational::FPS_120);
        let id = Id::new(1);
        g.add_node(Node::op(id, Domain::Gpu, Rate::Inherit))
            .expect("add");
        let p = g.placements().expect("legal graph");
        assert_eq!(p[&id].rate, CookRate::Periodic(Rational::FPS_120));
        assert_eq!(
            p[&id].rate.period(),
            Some(Rational::new(1, 120)),
            "the period must stay exact"
        );
    }

    #[test]
    fn rate_resolution_does_not_depend_on_node_insertion_order() {
        // Regression: the backwards pass once followed delayed edges, which it
        // is only order-correct over immediate ones. `fb` would resolve to 44
        // or to 60 for the same graph depending purely on which of the two
        // zero-in-degree nodes was added first.
        fn resolve(fb_first: bool) -> CookRate {
            let mut g = CookGraph::new(Rational::FPS_60);
            let (fb, map, sink) = (Id::new(1), Id::new(2), Id::new(3));
            let add = |g: &mut CookGraph, id| {
                g.add_node(Node::op(id, Domain::Cpu, Rate::Inherit)).expect("add");
            };
            if fb_first {
                add(&mut g, fb);
                add(&mut g, map);
            } else {
                add(&mut g, map);
                add(&mut g, fb);
            }
            g.add_node(Node::op(sink, Domain::Cpu, Rate::Fixed(dmx())))
                .expect("add");
            g.connect_delayed(fb, map).expect("connect");
            g.connect(map, sink).expect("connect");
            g.placements().expect("legal graph")[&fb].rate
        }

        assert_eq!(
            resolve(true),
            resolve(false),
            "the same graph must resolve the same way whatever order it was built in"
        );
    }

    #[test]
    fn domain_resolution_does_not_depend_on_node_insertion_order() {
        // Regression: `resolve_domains` ran one forward and one backward sweep
        // over a topological order that only respects *immediate* edges, but
        // propagated across delayed ones too. A delayed edge that runs
        // backwards through that order left its producer undecided, so the
        // producer fell through to the `Cpu` default and the edge then looked
        // like an implicit crossing.
        //
        // Concretely: `e2` feeds `e1` as feedback, `e1` feeds a GPU sink. Both
        // Either nodes belong on the GPU. Adding `e1` before `e2` rejected the
        // patch outright; adding `e2` first accepted it. Same graph, same
        // edges, different day.
        fn resolve(e1_first: bool) -> Result<BTreeMap<Id, Placement>, GraphError> {
            let mut g = CookGraph::new(Rational::FPS_60);
            let (e1, e2, sink) = (Id::new(1), Id::new(2), Id::new(3));
            let add = |g: &mut CookGraph, id| {
                g.add_node(Node::op(id, Domain::Either, Rate::Inherit))
                    .expect("add");
            };
            if e1_first {
                add(&mut g, e1);
                add(&mut g, e2);
            } else {
                add(&mut g, e2);
                add(&mut g, e1);
            }
            g.add_node(Node::op(sink, Domain::Gpu, Rate::Inherit))
                .expect("add");
            g.connect(e1, sink).expect("connect");
            g.connect_delayed(e2, e1).expect("connect");
            g.placements()
        }

        let first = resolve(true).expect("a GPU feedback pair is a legal graph");
        let second = resolve(false).expect("and still legal built the other way round");
        assert_eq!(
            first, second,
            "the same graph must place the same way whatever order it was built in"
        );
        for (id, p) in &first {
            assert_eq!(p.domain, Domain::Gpu, "{id} belongs on the GPU with its sink");
        }
    }

    #[test]
    fn an_either_chain_behind_a_feedback_edge_still_resolves() {
        // The same hazard one link deeper, which a single extra sweep would
        // not have fixed: two Either nodes chained behind the delayed edge, so
        // the propagation has to reach a fixed point rather than just run
        // twice.
        let mut g = CookGraph::new(Rational::FPS_60);
        let (a, b, c, sink) = (Id::new(1), Id::new(2), Id::new(3), Id::new(4));
        for id in [a, b, c] {
            g.add_node(Node::op(id, Domain::Either, Rate::Inherit))
                .expect("add");
        }
        g.add_node(Node::op(sink, Domain::Gpu, Rate::Inherit))
            .expect("add");
        g.connect(a, sink).expect("connect");
        g.connect_delayed(b, a).expect("connect");
        g.connect_delayed(c, b).expect("connect");

        let p = g.placements().expect("legal graph");
        for id in [a, b, c, sink] {
            assert_eq!(p[&id].domain, Domain::Gpu, "{id} should have followed the sink");
        }
    }

    #[test]
    #[should_panic(expected = "composition rate must be positive")]
    fn a_zero_composition_rate_is_refused() {
        // Unchecked it does not fail, it lies: every GPU root resolves to
        // `Periodic(0/1)`, `hz()` reports 0.0 and `period()` reports `None`.
        let _ = CookGraph::new(Rational::new(0, 1));
    }

    #[test]
    #[should_panic(expected = "composition rate must be positive")]
    fn a_negative_composition_rate_is_refused() {
        // Worse than zero: this used to resolve to `Periodic(-60/1)`, whose
        // `period()` is a *negative* Rational handed straight to the scheduler.
        let _ = CookGraph::new(Rational::new(-60, 1));
    }

    #[test]
    fn an_edit_that_lands_while_a_node_is_cooking_is_not_lost() {
        // The mirror of `work_dropped_for_a_deadline_stays_dirty`: there the
        // scheduler under-reports, here a parameter arrives after the plan
        // sampled it. Clearing self-dirty on commit regardless would retire an
        // edit the cook that just finished never saw.
        let mut f = Fix::new();
        let a = f.cpu(Rate::OnChange);
        f.pass();
        assert!(f.g.plan().expect("plan").cook.is_empty());

        f.g.touch(a).expect("touch");
        let plan = f.g.plan().expect("plan");
        assert!(plan.will_cook(a));
        // Second edit arrives mid-frame, after `a` read its parameters.
        f.g.touch(a).expect("touch");
        f.g.commit(&plan).expect("commit");

        assert!(
            f.g.plan().expect("plan").will_cook(a),
            "the second edit must survive the commit of the cook that predated it"
        );
        let settle = f.pass();
        assert!(settle.will_cook(a));
        assert!(
            f.g.plan().expect("plan").cook.is_empty(),
            "and then it settles — one re-cook, not a permanent dirty flag"
        );
    }

    #[test]
    fn a_fixed_rate_of_zero_is_rejected() {
        let mut g = CookGraph::new(Rational::FPS_60);
        let id = Id::new(1);
        assert_eq!(
            g.add_node(Node::op(id, Domain::Cpu, Rate::Fixed(Rational::new(0, 1)))),
            Err(GraphError::InvalidRate(id))
        );
    }

    // ── batching ─────────────────────────────────────────────────────────────

    #[test]
    fn contiguous_same_domain_same_rate_nodes_form_one_batch() {
        let mut f = Fix::new();
        let chain: Vec<Id> = (0..4).map(|_| f.gpu()).collect();
        for w in chain.windows(2) {
            f.link(w[0], w[1]);
        }

        let plan = f.g.plan().expect("plan");
        assert_eq!(plan.batches.len(), 1);
        assert_eq!(plan.batches[0].nodes, chain);
        assert_eq!(plan.batches[0].domain, Domain::Gpu);
        assert_eq!(plan.batches[0].kind, BatchKind::Work);
    }

    #[test]
    fn independent_branches_are_not_interleaved_into_single_node_batches() {
        // Two chains with no dependency between them. A naive topological order
        // can alternate GPU, CPU, GPU, CPU and shatter batching; the order must
        // prefer to finish a batch.
        let mut f = Fix::new();
        let mut gpu = Vec::new();
        let mut cpu = Vec::new();
        for _ in 0..3 {
            gpu.push(f.gpu());
            cpu.push(f.cpu(Rate::Fixed(dmx())));
        }
        for w in gpu.windows(2) {
            f.link(w[0], w[1]);
        }
        for w in cpu.windows(2) {
            f.link(w[0], w[1]);
        }

        let plan = f.g.plan().expect("plan");
        assert_eq!(
            plan.batches.len(),
            2,
            "expected one GPU and one CPU batch, got {:?}",
            plan.batches
        );
        let domains: BTreeSet<Domain> = plan.batches.iter().map(|b| b.domain).collect();
        assert_eq!(domains, BTreeSet::from([Domain::Gpu, Domain::Cpu]));

        // Reordering for batch affinity must not have bought throughput by
        // breaking a dependency.
        for edge in f.g.edges() {
            assert!(
                position(&plan.order, edge.from) < position(&plan.order, edge.to),
                "{} must still precede {}",
                edge.from,
                edge.to
            );
        }
    }

    #[test]
    fn a_rate_change_splits_a_batch_within_one_domain() {
        let mut f = Fix::new();
        let a = f.cpu(Rate::Fixed(dmx()));
        let b = f.cpu(Rate::Fixed(dmx()));
        let c = f.cpu(Rate::Fixed(Rational::new(30, 1)));
        f.link(a, b);
        f.link(b, c);

        let plan = f.g.plan().expect("plan");
        assert_eq!(plan.batches.len(), 2);
        assert_eq!(plan.batches[0].nodes, vec![a, b]);
        assert_eq!(plan.batches[1].nodes, vec![c]);
    }

    #[test]
    fn a_crossing_is_never_batched_with_ordinary_work() {
        let mut f = Fix::new();
        let g1 = f.gpu();
        let g2 = f.gpu();
        let back = f.readback(4096, 2);
        let c1 = f.cpu(Rate::Fixed(dmx()));
        let c2 = f.cpu(Rate::Fixed(dmx()));
        f.link(g1, g2);
        f.link(g2, back);
        f.link(back, c1);
        f.link(c1, c2);

        let plan = f.g.plan().expect("plan");
        assert_eq!(
            plan.batches.len(),
            3,
            "GPU work, the crossing alone, then CPU work: {:?}",
            plan.batches
        );
        assert_eq!(plan.batches[0].nodes, vec![g1, g2]);
        assert_eq!(plan.batches[1].kind, BatchKind::Crossing);
        assert_eq!(plan.batches[1].nodes, vec![back]);
        assert_eq!(plan.batches[2].nodes, vec![c1, c2]);
    }

    #[test]
    fn batches_partition_the_cook_list_in_order() {
        let mut f = Fix::new();
        let video = f.video();
        let effect = f.gpu();
        let back = f.readback(4096, 2);
        let analyse = f.cpu(Rate::Inherit);
        let sink = f.cpu(Rate::Fixed(dmx()));
        f.link(video, effect);
        f.link(effect, back);
        f.link(back, analyse);
        f.link(analyse, sink);

        let plan = f.g.plan().expect("plan");
        let flattened: Vec<Id> = plan.batches.iter().flat_map(|b| b.nodes.clone()).collect();
        assert_eq!(flattened, plan.cook, "batches must cover the cook list exactly");

        for batch in &plan.batches {
            for id in &batch.nodes {
                let p = plan.placement(*id).expect("placed");
                assert_eq!((p.domain, p.rate), (batch.domain, batch.rate));
                assert_ne!(p.domain, Domain::Either, "placement must be concrete");
            }
        }
    }

    #[test]
    fn batching_only_covers_what_is_actually_stale() {
        let mut f = Fix::new();
        let video = f.video();
        let from_video = f.gpu();
        let still = f.gpu();
        f.link(video, from_video);
        f.pass();

        let plan = f.g.plan().expect("plan");
        assert_eq!(plan.cook, vec![video, from_video]);
        assert!(!plan.cook.contains(&still));
        assert_eq!(plan.batches.len(), 1);
        assert_eq!(plan.batches[0].nodes, vec![video, from_video]);
    }

    #[test]
    fn order_and_batching_hold_across_randomised_graphs() {
        // The hand-built cases above each pin one shape. This walks 200
        // pseudo-random DAGs — wide, deep, diamond-heavy, with delayed edges
        // woven through — and re-checks every property the scheduler relies on
        // at once, which is where a reordering change is most likely to break
        // something no single fixture noticed.
        let mut rng = 0x2545_F491_4F6C_DD1D_u64;
        let mut next = move || {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng
        };

        // Guards against the generator drifting into shapes that make the
        // assertions vacuous.
        let (mut multi_batch, mut still_cooking, mut with_feedback) = (0, 0, 0);

        for case in 0..200 {
            let n = 4 + (next() % 40) as usize;
            let mut g = CookGraph::new(Rational::FPS_60);
            let ids: Vec<Id> = (0..n).map(|i| Id::new(i as u64 + 1)).collect();

            // All GPU, so domain resolution is not what is under test; the
            // rates vary, which is what splits batches.
            for &id in &ids {
                let rate = match next() % 4 {
                    0 => Rate::Inherit,
                    1 => Rate::Fixed(dmx()),
                    2 => Rate::Fixed(Rational::new(30, 1)),
                    _ => Rate::OnChange,
                };
                let node = Node::op(id, Domain::Gpu, rate);
                let node = if next() % 5 == 0 { node.driven_by_time() } else { node };
                g.add_node(node).expect("add");
            }

            // Edges only ever run low -> high, so the immediate subgraph is
            // acyclic by construction and a correct order is simply one that
            // never puts a higher index before a lower one it depends on.
            let mut immediate: Vec<(usize, usize)> = Vec::new();
            for to in 1..n {
                for _ in 0..(next() % 3) {
                    let from = (next() as usize) % to;
                    g.connect(ids[from], ids[to]).expect("connect");
                    immediate.push((from, to));
                }
            }
            // Delayed edges in any direction, including self-loops: they must
            // carry data without constraining order or tripping cycle
            // detection.
            let delayed = next() % 6;
            for _ in 0..delayed {
                let from = (next() as usize) % n;
                let to = (next() as usize) % n;
                g.connect_delayed(ids[from], ids[to]).expect("connect");
            }
            if delayed > 0 {
                with_feedback += 1;
            }

            let plain = g.order().expect("delayed edges are never a cycle");
            let plan = g.plan().expect("plan");
            let placements = g.placements().expect("placements");

            for order in [&plain, &plan.order] {
                assert_eq!(order.len(), n, "case {case}: every node must be ordered");
                let seen: BTreeSet<Id> = order.iter().copied().collect();
                assert_eq!(seen.len(), n, "case {case}: a node was emitted twice");
                for &(from, to) in &immediate {
                    assert!(
                        position(order, ids[from]) < position(order, ids[to]),
                        "case {case}: {} must precede {}",
                        ids[from],
                        ids[to]
                    );
                }
            }

            // `cook` is a subsequence of `order` — not merely a subset, or a
            // batch could be handed work out of dependency order.
            let mut cursor = 0;
            for &id in &plan.cook {
                let at = plan.order[cursor..]
                    .iter()
                    .position(|&x| x == id)
                    .unwrap_or_else(|| panic!("case {case}: {id} cooks but is out of order"));
                cursor += at + 1;
            }

            // Batches partition the cook list exactly, in order.
            let flat: Vec<Id> = plan.batches.iter().flat_map(|b| b.nodes.clone()).collect();
            assert_eq!(flat, plan.cook, "case {case}: batches must cover `cook`");

            if plan.batches.len() > 1 {
                multi_batch += 1;
            }
            for batch in &plan.batches {
                assert!(!batch.nodes.is_empty(), "case {case}: empty batch");
                if batch.kind == BatchKind::Crossing {
                    assert_eq!(batch.nodes.len(), 1, "case {case}: crossings never merge");
                }
                for id in &batch.nodes {
                    let p = placements[id];
                    assert_ne!(p.domain, Domain::Either, "case {case}: {id} unresolved");
                    assert_eq!(
                        (p.domain, p.rate),
                        (batch.domain, batch.rate),
                        "case {case}: {id} is in a batch it does not belong to"
                    );
                }
            }

            // A pass must settle: after committing everything, no node
            // re-cooks without a reason. The only reasons are being driven by
            // time, reading a feedback edge (whose producer advanced a
            // generation during the pass just committed), or sitting
            // downstream of something that is re-cooking for one of those.
            g.commit(&plan).expect("commit");
            let second = g.plan().expect("plan");
            let recooking: BTreeSet<Id> = second.cook.iter().copied().collect();
            if !recooking.is_empty() {
                still_cooking += 1;
            }
            for &id in &second.cook {
                let node = *g.node(id).expect("node");
                let driven = g.edges().any(|e| {
                    e.to == id
                        && (e.timing == EdgeTiming::Delayed || recooking.contains(&e.from))
                });
                assert!(
                    node.time_dependent || driven,
                    "case {case}: {id} re-cooked with nothing driving it"
                );
            }
        }

        assert!(multi_batch > 20, "only {multi_batch} cases split into batches");
        assert!(still_cooking > 20, "only {still_cooking} cases kept cooking");
        assert!(with_feedback > 20, "only {with_feedback} cases had feedback");
    }

    #[test]
    fn a_deep_chain_orders_exactly_and_without_recursing() {
        // 2,000 deep. Kahn and the cycle walk are both iterative; a recursive
        // reimplementation would overflow here rather than return a wrong
        // answer, which is the failure mode worth pinning.
        let mut f = Fix::new();
        let chain: Vec<Id> = (0..2_000).map(|_| f.gpu()).collect();
        for w in chain.windows(2) {
            f.link(w[0], w[1]);
        }
        assert_eq!(f.g.order().expect("order"), chain);

        let plan = f.g.plan().expect("plan");
        assert_eq!(plan.cook, chain);
        assert_eq!(plan.batches.len(), 1, "one domain, one rate, one batch");

        // And the same depth as a cycle: the loop must be named, not hung on.
        f.link(chain[1_999], chain[0]);
        let GraphError::Cycle { nodes } = f.g.order().expect_err("cycle") else {
            panic!("expected a cycle");
        };
        assert_eq!(nodes.len(), 2_000);
    }

    // ── bookkeeping ──────────────────────────────────────────────────────────

    #[test]
    fn duplicate_and_unknown_nodes_are_rejected() {
        let mut g = CookGraph::new(Rational::FPS_60);
        let a = Id::new(1);
        g.add_node(Node::op(a, Domain::Gpu, Rate::Inherit))
            .expect("add");
        assert_eq!(
            g.add_node(Node::op(a, Domain::Cpu, Rate::OnChange)),
            Err(GraphError::DuplicateNode(a))
        );
        let ghost = Id::new(99);
        assert_eq!(g.connect(a, ghost), Err(GraphError::UnknownNode(ghost)));
        assert_eq!(g.touch(ghost), Err(GraphError::UnknownNode(ghost)));
        assert_eq!(g.len(), 1);
        assert!(!g.is_empty());
    }

    #[test]
    fn an_empty_graph_plans_to_nothing() {
        let g = CookGraph::new(Rational::FPS_60);
        let plan = g.plan().expect("plan");
        assert!(plan.order.is_empty() && plan.cook.is_empty() && plan.batches.is_empty());
        assert_eq!(plan.crossing_bytes_per_second(), 0.0);
        assert!(g.is_empty());
    }

    #[test]
    fn the_cycle_message_names_the_nodes_and_suggests_the_fix() {
        let mut f = Fix::new();
        let (a, b) = (f.gpu(), f.gpu());
        f.link(a, b);
        f.link(b, a);
        let msg = f.g.order().expect_err("cycle").to_string();
        assert!(msg.contains(&a.to_string()) && msg.contains(&b.to_string()), "{msg}");
        assert!(msg.contains("delayed edge"), "{msg}");
    }

    #[test]
    fn composition_rate_is_what_the_graph_was_built_with() {
        let g = CookGraph::new(Rational::FPS_29_97);
        assert_eq!(g.composition_rate(), Rational::FPS_29_97);
        let id = Id::new(1);
        let mut g = g;
        g.add_node(Node::op(id, Domain::Gpu, Rate::Inherit))
            .expect("add");
        // 30000/1001 inherited intact, not rounded to 29.97 or to 30.
        assert_eq!(
            g.placements().expect("legal graph")[&id].rate,
            CookRate::Periodic(Rational::new(30000, 1001))
        );
    }
}

