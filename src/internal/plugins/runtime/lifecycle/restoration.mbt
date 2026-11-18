///|
// The application has independently reverified immutable package bytes and
// matched their manifest to the durable approved index before calling this.
pub(all) struct RestoredPackage {
  content : PackageContent
  desired_enabled : Bool
  grants : Array[ContributionGrant]
}

///|
// Startup only: no health execution and no durable publication occurs here.
// A failed validation changes nothing; a successful empty restore still seals
// this entry point. Runtime identities are new for this process, not disk IDs.
pub fn Runtime::restore_packages(
  self : Runtime,
  packages : Array[RestoredPackage],
) -> Bool {
  if self.closing ||
    self.bootstrapped ||
    self.next_id != 1 ||
    packages.length() > 64 {
    return false
  }
  let staged : Map[String, PackageRecord] = Map([])
  let mut generation = 1
  for entry in packages {
    if !content_valid(entry.content) ||
      staged.contains(entry.content.package_id) {
      return false
    }
    let copied = match checked_grants(entry.grants) {
      Some(grants) => grants
      None => return false
    }
    let grants : Map[String, GrantRecord] = Map([])
    for id, effect in copied {
      grants[id] = { effect, generation, }
    }
    staged[entry.content.package_id] = {
      content: entry.content,
      generation,
      install_generation: generation,
      desired_enabled: entry.desired_enabled,
      grants,
    }
    generation += 1
  }
  for id, installed in staged {
    self.packages[id] = installed
    self.generations[id] = installed.generation
  }
  self.next_id = generation
  self.bootstrapped = true
  true
}
