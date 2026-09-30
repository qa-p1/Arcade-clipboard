use std::{fs::{File, OpenOptions, TryLockError}, path::Path};

/// Prevent two app instances from creating/replacing one secure identity or
/// mutating the same profile concurrently. The OS releases this lock on crash.
/// Never unlink the file: that would permit separate locks on different inodes.
pub(crate) struct ProfileLock {
    _file: File,
}

impl ProfileLock {
    pub(crate) fn acquire(directory: &Path) -> Result<Self, String> {
        let file = OpenOptions::new().read(true).write(true).create(true)
            .truncate(false).open(directory.join("profile.lock"))
            .map_err(|_| "Could not open the clipboard profile lock".to_string())?;
        match file.try_lock() {
            Ok(()) => Ok(Self { _file: file }),
            Err(TryLockError::WouldBlock) => Err("This clipboard profile is already open. Close the other instance or use a different data folder.".into()),
            Err(TryLockError::Error(_)) => Err("This filesystem cannot safely lock the clipboard profile".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrent_open_is_rejected_and_drop_releases_lock() {
        let directory = tempfile::tempdir().unwrap();
        let first = ProfileLock::acquire(directory.path()).unwrap();
        assert!(ProfileLock::acquire(directory.path()).is_err());
        drop(first);
        assert!(ProfileLock::acquire(directory.path()).is_ok());
    }

    #[test]
    fn independent_profiles_do_not_share_a_lock() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let _a = ProfileLock::acquire(a.path()).unwrap();
        let _b = ProfileLock::acquire(b.path()).unwrap();
    }
}
