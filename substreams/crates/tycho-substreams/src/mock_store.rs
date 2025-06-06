//! Contains a mock store for internal testing.
//!
//! Might make this public alter to users can test their store handlers.
use std::{cell::RefCell, collections::HashMap, rc::Rc};
use substreams::{
    prelude::{BigInt, StoreDelete, StoreGet, StoreSet, StoreSetSum, StoreNew, StoreAppend, Appender},
    store::StoreAdd,
};

type BigIntStore = HashMap<String, Vec<(u64, BigInt)>>; //can't we just make the store generic?
//lol yes, but for types like proto will have to be impl'd different 
// type ProtoStore = HashMap<String, Vec<(u64, Proto)>>;

#[derive(Debug, Clone)]
pub struct MockStore {
    data: Rc<RefCell<BigIntStore>>,
}

impl StoreDelete for MockStore {
    fn delete_prefix(&self, _ord: i64, prefix: &String) {
        self.data
            .borrow_mut()
            .retain(|k, _| !k.starts_with(prefix));
    }
}

impl StoreNew for MockStore {
    fn new() -> Self {
        Self { data: Rc::new(RefCell::new(HashMap::new())) }
    }
}

impl StoreAdd<BigInt> for MockStore {
    fn add<K: AsRef<str>>(&self, ord: u64, key: K, value: BigInt) {
        let mut guard = self.data.borrow_mut();
        guard
            .entry(key.as_ref().to_string())
            .and_modify(|v| {
                let prev_value = v.last().unwrap().1.clone();
                v.push((ord, prev_value + value.clone()));
            })
            .or_insert(vec![(ord, value)]);
    }

    fn add_many<K: AsRef<str>>(&self, ord: u64, keys: &Vec<K>, value: BigInt) {
        keys.iter().for_each(|key| self.add(ord, key, value.clone()));
    }
}

impl StoreGet<BigInt> for MockStore {
    fn new(_idx: u32) -> Self {
        Self { data: Rc::new(RefCell::new(HashMap::new())) }
    }

    fn get_at<K: AsRef<str>>(&self, ord: u64, key: K) -> Option<BigInt> {
        self.data
            .borrow()
            .get(&key.as_ref().to_string())
            .map(|v| {
                v.iter()
                    .find(|(current_ord, _)| *current_ord == ord)
                    .unwrap()
                    .1
                    .clone()
            })
    }

    fn get_last<K: AsRef<str>>(&self, key: K) -> Option<BigInt> {
        self.data
            .borrow()
            .get(&key.as_ref().to_string())
            .map(|v| v.last().unwrap().1.clone())
    }

    fn get_first<K: AsRef<str>>(&self, key: K) -> Option<BigInt> {
        self.data
            .borrow()
            .get(&key.as_ref().to_string())
            .map(|v| v.first().unwrap().1.clone())
    }

    fn has_at<K: AsRef<str>>(&self, ord: u64, key: K) -> bool {
        self.data
            .borrow()
            .get(&key.as_ref().to_string())
            .map(|v| v.iter().any(|(v, _)| *v == ord))
            .unwrap_or(false)
    }

    fn has_last<K: AsRef<str>>(&self, key: K) -> bool {
        self.get_last(key).is_some()
    }

    fn has_first<K: AsRef<str>>(&self, key: K) -> bool {
        self.get_first(key).is_some()
    }
}

impl StoreSet<BigInt> for MockStore {
    /// Set a given key to a given value, if the key existed before, it will be replaced.
    fn set<K: AsRef<str>>(&self, ord: u64, key: K, value: &V) {
        let mut guard = self.data.borrow_mut();
        guard
            .entry(key.as_ref().to_string())
            .insert(vec![(ord, value)]);
    }
    /// Set many keys to a given value, if the key existed before, it will be replaced.
    fn set_many<K: AsRef<str>>(&self, ord: u64, keys: &Vec<K>, value: &V) {
        keys.iter().for_each(|key| self.set(ord, key, value.clone()));
    }
}

impl Appender<BigInt> for MockStore //idk whether BigInt impls Into<String>
{
    fn new() -> Self {
        StoreAppend {
            data: Rc::new(RefCell::new(String::new()))
        }
    }

    fn append<K: AsRef<str>>(&self, ord: u64, key: K, item: T) {
        // let item: String = item.into();
        // let v = &format!("{};", &item).as_bytes();
        // let guard = self.data.borrow_mut();
        // guard.push_str(v);
    }

    fn append_all<K: AsRef<str>>(&self, ord: u64, key: K, items: Vec<T>) {
        items.iter().for_each(|key| self.append(ord, key, value.clone()))
    }
}

impl StoreSetSum<BigInt> for MockStore {
    fn new() -> Self {
        Self { data: Rc::new(RefCell::new(HashMap::new())) }
    }

    fn set<K: AsRef<str>>(&self, ord: u64, key: K, value: T) {
        let mut guard = self.data.borrow_mut();
        let v = format!("set:{}", value.to_string());
        //have to put a format string inside it too 
        guard
            .entry(key.as_ref().to_string())
            .insert(vec![(ord, v)]);
    }

    fn sum<K: AsRef<str>>(&self, ord: u64, key: K, value: T) {
        let mut guard = self.data.borrow_mut();
        let v = format!("sum:{}", value.to_string());  
        guard
            .entry(key.as_ref().to_string())
            .and_modify(|v| {
                let prev_value = v.last().unwrap().1.clone();
                //have to put a format string inside it too   
                v.push((ord, prev_value + value.clone()));
            })
            .or_insert(vec![(ord, v)]);
    }
}

impl StoreSetIfNotExists<BigInt> for MockStore {
    fn set_if_not_exists<K: AsRef<str>>(&self, ord: u64, key: K, value: &BigInt) {
        let mut guard = self.data.borrow_mut();
        if !guard.contains_key(key.as_ref()) {             
             guard
               .entry(key.as_ref().to_string())
               .insert(vec![(ord, value)]);
        }
    }

    fn set_if_not_exists_many<K: AsRef<str>>(&self, ord: u64, keys: &Vec<K>, value: &BigInt) {
        keys
            .iter()
            .for_each(|key| self.set_if_not_exists(ord, key, value.clone()));
    }
}