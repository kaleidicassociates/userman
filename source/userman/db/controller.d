/**
	Database abstraction layer

	Copyright: © 2012-2015 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.db.controller;

public import userman.userman;
import userman.id;

import vibe.crypto.passwordhash;
import vibe.data.serialization;
import vibe.db.mongo.mongo;
import vibe.http.router;
import vibe.mail.smtp;
import vibe.stream.memory;
import vibe.templ.diet;
import vibe.utils.validation;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.random;
import std.string;
import std.typecons : Nullable;


UserManController createUserManController(UserManSettings settings)
{
	import userman.db.file;
	import userman.db.mongo;
	import userman.db.redis;
	
	auto url = settings.databaseURL;
	if (url.startsWith("redis://")) return new RedisUserManController(settings);
	else if (url.startsWith("mongodb://")) return new MongoUserManController(settings);
	else if (url.startsWith("file://")) return new FileUserManController(settings);
	else throw new Exception("Unknown URL schema: "~url);
}

class UserManController {
	protected {
		UserManSettings m_settings;
	}
	
	this(UserManSettings settings)
	{	
		m_settings = settings;
	}

	@property UserManSettings settings() { return m_settings; }

	abstract bool isEmailRegistered(string email);

	void validateUser(in ref User usr)
	{
		enforce(usr.name.length >= 3, "User names must be at least 3 characters long.");
		validateEmail(usr.email);
	}
	
	abstract User.ID addUser(ref User usr);

	User.ID registerUser(string email, string name, string full_name, string password)
	{
		email = email.toLower();
		name = name.toLower();

		validateEmail(email);
		validatePassword(password, password);

		auto need_activation = m_settings.requireAccountValidation;
		User user;
		user.active = !need_activation;
		user.name = name;
		user.fullName = full_name;
		user.auth.method = "password";
		user.auth.passwordHash = generateSimplePasswordHash(password);
		user.email = email;
		if( need_activation )
			user.activationCode = generateActivationCode();

		addUser(user);
		
		if( need_activation )
			resendActivation(email);

		return user.id;
	}

	User.ID inviteUser(string email, string full_name, string message, bool send_mail = true)
	{
		email = email.toLower();

		validateEmail(email);

		try {
			return getUserByEmail(email).id;
		}
		catch (Exception e) {
			User user;
			user.email = email;
			user.name = email;
			user.fullName = full_name;
			addUser(user);

			if( m_settings.mailSettings ){
				auto msg = new MemoryOutputStream;
				auto serviceName = m_settings.serviceName;
				auto serviceUrl = m_settings.serviceUrl;
				compileDietFile!("userman.mail.invitation.dt", user, serviceName, serviceUrl)(msg);

				auto mail = new Mail;
				mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
				mail.headers["To"] = email;
				mail.headers["Subject"] = "Invitation";
				mail.headers["Content-Type"] = "text/html; charset=UTF-8";
				mail.bodyText = cast(string)msg.data();
				
				sendMail(m_settings.mailSettings, mail);
			}

			return user.id;
		}
	}

	Nullable!(User.ID) testLogin(string name, string password)
	{
		auto user = getUserByEmailOrName(name);
		if (testSimplePasswordHash(user.auth.passwordHash, password))
			return Nullable!(User.ID)(user.id);
		return Nullable!(User.ID).init;
	}

	void activateUser(string email, string activation_code)
	{
		email = email.toLower();

		auto user = getUserByEmail(email);
		enforce(!user.active, "This user account is already activated.");
		enforce(user.activationCode == activation_code, "The activation code provided is not valid.");
		user.active = true;
		user.activationCode = "";
		updateUser(user);
	}
	
	void resendActivation(string email)
	{
		email = email.toLower();

		auto user = getUserByEmail(email);
		enforce(!user.active, "The user account is already active.");
		
		auto msg = new MemoryOutputStream;
		auto serviceName = m_settings.serviceName;
		auto serviceUrl = m_settings.serviceUrl;
		compileDietFile!("userman.mail.activation.dt", user, serviceName, serviceUrl)(msg);

		auto mail = new Mail;
		mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
		mail.headers["To"] = email;
		mail.headers["Subject"] = "Account activation";
		mail.headers["Content-Type"] = "text/html; charset=UTF-8";
		mail.bodyText = cast(string)msg.data();
		
		sendMail(m_settings.mailSettings, mail);
	}

	void requestPasswordReset(string email)
	{
		auto usr = getUserByEmail(email);

		string reset_code = generateActivationCode();
		SysTime expire_time = Clock.currTime() + dur!"hours"(24);
		usr.resetCode = reset_code;
		usr.resetCodeExpireTime = expire_time;
		updateUser(usr);

		if( m_settings.mailSettings ){
			auto msg = new MemoryOutputStream;
			auto user = &usr;
			auto settings = m_settings;
			compileDietFile!("userman.mail.reset_password.dt", user, reset_code, settings)(msg);

			auto mail = new Mail;
			mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
			mail.headers["To"] = email;
			mail.headers["Subject"] = "Account recovery";
			mail.headers["Content-Type"] = "text/html; charset=UTF-8";
			mail.bodyText = cast(string)msg.data();
			sendMail(m_settings.mailSettings, mail);
		}
	}

	void resetPassword(string email, string reset_code, string new_password)
	{
		validatePassword(new_password, new_password);
		auto usr = getUserByEmail(email);
		enforce(usr.resetCode.length > 0, "No password reset request was made.");
		enforce(Clock.currTime() < usr.resetCodeExpireTime, "Reset code is expired, please request a new one.");
		auto code = usr.resetCode;
		usr.resetCode = "";
		updateUser(usr);
		enforce(reset_code == code, "Invalid request code, please request a new one.");
		usr.auth.passwordHash = generateSimplePasswordHash(new_password);
		updateUser(usr);
	}

	abstract User getUser(User.ID id);

	abstract User getUserByName(string name);

	abstract User getUserByEmail(string email);

	abstract User getUserByEmailOrName(string email_or_name);

	abstract void enumerateUsers(long first_user, long max_count, scope void delegate(ref User usr) @safe del);
	final void enumerateUsers(long first_user, long max_count, scope void delegate(ref User usr) del) {
		enumerateUsers(first_user, max_count, (ref usr) @trusted { del(usr); });
	}

	abstract long getUserCount();

	abstract void deleteUser(User.ID user_id);

	abstract void updateUser(in ref User user);
	abstract void setEmail(User.ID user, string email);
	abstract void setFullName(User.ID user, string full_name);
	abstract void setPassword(User.ID user, string password);
	abstract void setProperty(User.ID user, string name, Json value);
	abstract void removeProperty(User.ID user, string name);

	abstract void addGroup(string id, string description);
	abstract void removeGroup(string name);
	abstract void setGroupDescription(string name, string description);
	abstract long getGroupCount();
	abstract Group getGroup(string id);
	abstract void enumerateGroups(long first_group, long max_count, scope void delegate(ref Group grp) @safe del);
	final void enumerateGroups(long first_group, long max_count, scope void delegate(ref Group grp) del) {
		enumerateGroups(first_group, max_count, (ref grp) @trusted { del(grp); });
	}
	abstract void addGroupMember(string group, User.ID user);
	abstract void removeGroupMember(string group, User.ID user);
	abstract long getGroupMemberCount(string group);
	abstract void enumerateGroupMembers(string group, long first_member, long max_count, scope void delegate(User.ID usr) @safe del);
	final void enumerateGroupMembers(string group, long first_member, long max_count, scope void delegate(User.ID usr) del) {
		enumerateGroupMembers(group, first_member, max_count, (usr) @trusted { del(usr); });
	}
	deprecated Group getGroupByName(string id) { return getGroup(id); }

	/** Test a group ID for validity.

		Valid group IDs consist of one or more dot separated identifiers, where
		each idenfifiers must contain only ASCII alphanumeric characters or
		underscores. Each identifier must begin with an alphabetic or underscore
		character.
	*/
	static bool isValidGroupID(string name)
	{
		import std.ascii : isAlpha, isDigit;
		import std.algorithm : splitter;

		if (name.length < 1) return false;
		foreach (p; name.splitter('.')) {
			if (p.length < 0) return false;
			if (!p[0].isAlpha && p[0] != '_') return false;
			if (p.canFind!(ch => !ch.isAlpha && !ch.isDigit && ch != '_'))
				return false;
		}
		return true;
	}
}

struct User {
	alias .ID!User ID;
	@(.name("_id")) ID id;
	bool active;
	bool banned;
	string name;
	string fullName;
	string email;
	string[] groups;
	string activationCode;
	string resetCode;
	SysTime resetCodeExpireTime;
	AuthInfo auth;
	Json[string] properties;

	bool isInGroup(string group) const { return groups.countUntil(group) >= 0; }
}

struct AuthInfo {
	string method = "password";
	string passwordHash;
	string token;
	string secret;
	string info;
}

struct Group {
	string id;
	string description;
	@optional Json[string] properties;
}


string generateActivationCode()
{
	auto ret = appender!string();
	foreach( i; 0 .. 10 ){
		auto n = cast(char)uniform(0, 62);
		if( n < 26 ) ret.put(cast(char)('a'+n));
		else if( n < 52 ) ret.put(cast(char)('A'+n-26));
		else ret.put(cast(char)('0'+n-52));
	}
	return ret.data();
}
