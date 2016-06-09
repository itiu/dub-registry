/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.repositories.github;

import dubregistry.cache;
import dubregistry.repositories.repository;
import std.string : startsWith;
import std.typecons;
import vibe.core.log;
import vibe.core.stream;
import vibe.data.json;
import vibe.inet.url;


class GithubRepository : Repository {
	private {
		string m_owner;
		string m_project;
		string m_authUser;
		string m_authPassword;

                string username = "";
                string password = "";
	}

	static void register(string user, string password)
	{
		Repository factory(Json info){
			return new GithubRepository(info.owner.get!string, info.project.get!string, user, password);
		}
		addRepositoryFactory("github", &factory);
	}

	this(string owner, string project, string auth_user, string auth_password)
	{
		m_owner = owner;
		m_project = project;
		m_authUser = auth_user;
		m_authPassword = auth_password;
	}

	RefInfo[] getTags()
	{
		import std.datetime : SysTime;

		Json tags;
		try tags = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/tags?per_page=100", username, password);
		catch( Exception e ) { throw new Exception("Failed to get tags: "~e.msg); }
		RefInfo[] ret;
		foreach_reverse (tag; tags) {
			try {
				auto tagname = tag.name.get!string;
				Json commit = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/commits/"~tag.commit.sha.get!string, username, password, true, true);
				ret ~= RefInfo(tagname, tag.commit.sha.get!string, SysTime.fromISOExtString(commit.commit.committer.date.get!string));
				logDebug("Found tag for %s/%s: %s", m_owner, m_project, tagname);
			} catch( Exception e ){
				throw new Exception("Failed to process tag "~tag.name.get!string~": "~e.msg);
			}
		}
		return ret;
	}

	RefInfo[] getBranches()
	{
		import std.datetime : SysTime;

		Json branches = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/branches", username, password);
		RefInfo[] ret;
		foreach_reverse( branch; branches ){
			auto branchname = branch.name.get!string;
			Json commit = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project~"/commits/"~branch.commit.sha.get!string, username, password, true, true);
			ret ~= RefInfo(branchname, branch.commit.sha.get!string, SysTime.fromISOExtString(commit.commit.committer.date.get!string));
			logDebug("Found branch for %s/%s: %s", m_owner, m_project, branchname);
		}
		return ret;
	}

	RepositoryInfo getInfo()
	{
		auto nfo = readJson(getAPIURLPrefix()~"/repos/"~m_owner~"/"~m_project, username, password);
		RepositoryInfo ret;
		ret.isFork = nfo["fork"].opt!bool;
		return ret;
	}

	void readFile(string commit_sha, Path path, scope void delegate(scope InputStream) reader)
	{
		assert(path.absolute, "Passed relative path to readFile.");
		auto url = getContentURLPrefix()~"/"~m_owner~"/"~m_project~"/"~commit_sha~path.toString();
		downloadCached(url, null, null, (scope input) {
			reader(input);
		}, true);
	}

	string getDownloadUrl(string ver)
	{
		if( ver.startsWith("~") ) ver = ver[1 .. $];
		else ver = ver;
		return "https://github.com/"~m_owner~"/"~m_project~"/archive/"~ver~".zip";
	}

	void download(string ver, scope void delegate(scope InputStream) del)
	{
		downloadCached(getDownloadUrl(ver), null, null, del);
	}

	private string getAPIURLPrefix() {
		if (m_authUser.length) return "https://"~m_authUser~":"~m_authPassword~"@api.github.com";
		else return "https://api.github.com";
	}

	private string getContentURLPrefix() {
		return "https://raw.github.com";
	}
}
