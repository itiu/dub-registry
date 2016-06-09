/**
	Copyright: © 2013-2014 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.cache;

import vibe.core.log;
import vibe.db.mongo.mongo;
import vibe.http.client;
import vibe.stream.memory;

import core.time;
import std.algorithm : startsWith;
import std.exception;


enum CacheMatchMode {
	always, // return cached data if available
	etag,   // return cached data if the server responds with "not modified"
	never   // always request fresh data
}


class URLCache {
	private {
		MongoClient m_db;
		MongoCollection m_entries;
		Duration m_maxCacheTime = 365.days;
	}

	this()
	{
		m_db = connectMongoDB("127.0.0.1");
		m_entries = m_db.getCollection("urlcache.entries");
		m_entries.ensureIndex(["url": true]);
	}

	void clearEntry(URL url)
	{
		m_entries.remove(["url": url.toString()]);
	}

	void get(URL url, scope void delegate(scope InputStream str) callback, bool cache_priority = false)
	{
		get(url, callback, cache_priority ? CacheMatchMode.always : CacheMatchMode.etag);
	}

	void get(URL url, scope void delegate(scope InputStream str) callback, CacheMatchMode mode = CacheMatchMode.etag)
	{
		import std.datetime : Clock, UTC;
		import vibe.http.auth.basic_auth;
		import dubregistry.internal.utils : black;

		auto user = url.username;
		auto password = url.password;
		url.username = null;
		url.password = null;

		InputStream result;
		bool handled_uncached = false;

		auto now = Clock.currTime(UTC());

		foreach (i; 0 .. 10) { // follow max 10 redirects
			auto be = m_entries.findOne(["url": url.toString()]);
			CacheEntry entry;
			if (!be.isNull()) {
				// invalidate out of date cache entries
				if (be._id.get!BsonObjectID.timeStamp < now - m_maxCacheTime)
					m_entries.remove(["_id": be._id]);
				
				deserializeBson(entry, be);
				if (mode == CacheMatchMode.always) {
					// directly return cache result for cache_priority == true
					logDiagnostic("Cache HIT (early): %s", url.toString());
					if (entry.redirectURL.length) {
						url = URL(entry.redirectURL);
						continue;
					} else {
						auto data = be["data"].get!BsonBinData().rawData();
						scope tmpresult = new MemoryStream(cast(ubyte[])data, false);
						callback(tmpresult);
						return;
					}
				}
			} else {
				entry._id = BsonObjectID.generate();
				entry.url = url.toString();
			}

			requestHTTP(url,
				(scope req){
					if (entry.etag.length && mode != CacheMatchMode.never) req.headers["If-None-Match"] = entry.etag;
					if (user.length) addBasicAuth(req, user, password);
				},
				(scope res){
					switch (res.statusCode) {
						default:
							throw new Exception("Unexpected reply for '"~url.toString().black~"': "~httpStatusText(res.statusCode));
						case HTTPStatus.notModified:
							logDiagnostic("Cache HIT: %s", url.toString());
							res.dropBody();
							auto data = be["data"].get!BsonBinData().rawData();
							result = new MemoryStream(cast(ubyte[])data, false);
							break;
						case HTTPStatus.notFound:
							res.dropBody();
							throw new FileNotFoundException("File '"~url.toString().black~"' does not exist.");
						case HTTPStatus.movedPermanently, HTTPStatus.found, HTTPStatus.temporaryRedirect:
							auto pv = "Location" in res.headers;
							enforce(pv !is null, "Server responded with redirect but did not specify the redirect location for "~url.toString());
							logDebug("Redirect to '%s'", *pv);
							if (startsWith((*pv), "http:") || startsWith((*pv), "https:")) {
								url = URL(*pv);
							} else url.localURI = *pv;
							res.dropBody();

							entry.redirectURL = url.toString();
							m_entries.update(["_id": entry._id], entry, UpdateFlags.Upsert);
							break;
						case HTTPStatus.ok:
							auto pet = "ETag" in res.headers;
							if (pet || mode == CacheMatchMode.always) {
								logDiagnostic("Cache MISS: %s", url.toString());
								auto dst = new MemoryOutputStream;
								dst.write(res.bodyReader);
								auto rawdata = dst.data;
								if (pet) entry.etag = *pet;
								entry.data = BsonBinData(BsonBinData.Type.Generic, cast(immutable)rawdata);
								m_entries.update(["_id": entry._id], entry, UpdateFlags.Upsert);
								result = new MemoryStream(rawdata, false);
								break;
							}

							logDebug("Response without etag.. not caching: "~url.toString());

							logDiagnostic("Cache MISS (no etag): %s", url.toString());
							handled_uncached = true;
							callback(res.bodyReader);
							break;
					}
				}
			);

			if (handled_uncached) return;

			if (result) {
				callback(result);
				return;
			}
		}

		throw new Exception("Too many redirects for "~url.toString().black);
	}
}

class FileNotFoundException : Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

private struct CacheEntry {
	BsonObjectID _id;
	string url;
	string etag;
	BsonBinData data;
	@optional string redirectURL;
}

private URLCache s_cache;

void downloadCached(URL url, scope void delegate(scope InputStream str) callback, bool cache_priority = false)
{
	if (!s_cache) s_cache = new URLCache;
	s_cache.get(url, callback, cache_priority);
}

void downloadCached(string url, string username, string password, scope void delegate(scope InputStream str) callback, bool cache_priority = false)
{
	URL _url = URL.parse (url);
	_url.username = username;
	_url.password = password;

	return downloadCached(_url, callback, cache_priority);
}

void clearCacheEntry(URL url)
{
	if (!s_cache) s_cache = new URLCache;
	s_cache.clearEntry(url);
}

void clearCacheEntry(string url)
{
	clearCacheEntry(URL(url));
}
