# Discovered Stacks Project: Neo Improvements

## Common Migration Pitfalls

- Lambdas and other resources not surfacing their code
    - Imports only capture surface level infrastructure state, not any of the actual application code which can only be retrieved by viewing the source repository.
- Chicken-and-egg problems with CloudFormation not reflecting parent/child relationships between resources
    - Some setups may have two multi-step deployments, such as first creating a bucket and then uploading an artifact used by other resources. Importing without inspecting the code may flatten this relationship and lose some hidden dependencies.
- Terraform resources being treated the same as unmanaged ones, and being invisible
    - Unlike CF and ARM which use dedicated "stack" objects, it is difficult to distinguish Terraform-managed resources from unmanaged or hand-created ones.
- Discovery has support for CloudFormation and Azure Resource Manager, but not GCP, which is already known.
- CloudFormation nested stack support for better organizing
    - Stack discovery has a tendency to flatten and discard nested stack hierarchy, which might be helpful to preserve.
- Looped resources being treated as individual resources
    - The import process has to individually transfer resources one by one. The only reliable way to ensure proper migration and determine whether a resource is unique or part of an array, is to inspect the source repository to see how they are constructed.
- Resources that are dynamically allocated and deallocated between scans
    - Dynamic allocation fundamentally requires inspecting the source code, as not all discovered stacks or resources within them may exist at the same time. The migration process should support this, as it is perfectly reasonable for a user to want to transfer complex setups like these to Pulumi where it would be a much cleaner implementation.

## Concerns in Relation to Discovered Stacks

Importing works well, and Neo successfully goes from beginning to end with analyzing resources, quering them for information, importing them, fixing CLI-generated code, running `preview`, and submitting a PR.

The main question is regarding the source repository. Without it, Neo effectively only replicates what the "Generate Import Commands" option already does: a working state transfer of the selected resources Pulumi, but limited capability for further development.

The user must do the remaining 80% of the work and recreate all remaining files, build systems, and deployment scripts.

Usable, production-grade code seems like it absolutely requires the source repo. And at that point, the problem becomes harder to separate from the larger overarching capability of "fully migrating all infrastructure to Pulumi."

## Case for Dedicated Migration Tools and Emphasis of Full Migration

Why not fall back to simplicity, keeping the current basic system of putting all target resources into the initial user prompt?

The scenario where someone imports into Pulumi without referencing the code that set those resources up is unlikely in practice, since the main value of Pulumi is infrastructure as code.

Once the source repo is involved, user expectations naturally rise, and arbitrary limits like "you can only convert a small number of hand-picked resources" may be disappointing. It may be more accurate to reframe the project around full code migration that uses a discovered stacks as the initial starting point.

## Implementation

The tool and scaffolding will function under the hood, and not require any user interaction.

Implementing asynchronous and new task types is complex and already being handled by the AI team, so we should avoid duplicating that work.

Add the option of attaching data to Neo tasks (either as a special hidden message or some abstract structure) that can be referenced by tools and will never be forgotten, hallucinated, or affected by context compression. Afterwards, set up a todo list to algorithmically iterate through the resources one-by-one using subagents. The inner subagent loop is broken and the main outer agent only has to consider the full resource list within its context if any specific resource runs into trouble or big questions arise.

Keep scaffolding model-agnostic. As seen with GPT-5.5, newer models will be released and continue to improve, so the focus should be on addressing the areas where LLMs uniquely struggle while. Technical execution and subjective choices would be left to the model as much possible.

Such an approach has a decent chance of being original, as if it weren't, Terraform marketing would no doubt be highlighting it.
