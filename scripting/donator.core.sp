/*
If you want to use SQL here is some info to get you started:

SQL TABLE INFO:

	CREATE TABLE IF NOT EXISTS `donators` (
	  `steamid` varchar(64) default NULL,
	  `tag` varchar(128) NOT NULL,
	  `level` tinyint(1) NOT NULL default '1'
	)

MANUALLY ADDING DONATORS:

	INSERT INTO `donators` ( `steamid` , `tag`, `level` ) VALUES ( 'STEAMID', 'THIS IS A TAG', 5 );

Flat File Setup:
	Create a file called donators.txt in sourcemod/data. (The plugin will not load if the file is missing).
	The file should have the following layout:
		STEAM_ID;LEVEL

*/

/*
* 	Change Log:
* 		v0.1 - inital release
* 		v0.2 - Fixed menu expandability/ trigger cmd
* 		v0.3 - Safe SQL calls, API additions/ changes
* 		v0.4 - Added option for using a flatfile
* 		v0.5 - Reworked SQL loading
* 		v0.6 - Corrected menu sorting
* 		v0.7 - FindDonatorBySteamId correction/ optimizations
* 		v0.8 - Proper tag reloading - reworked connect logic
*/

#include <sourcemod>
#include <sdktools>
#include <adt>
#include <donator>
#include <clientprefs>

#pragma semicolon 1

/*
* Uncomment to use a SQL database
*/
//#define USE_SQL

#define SQL_CONFIG		"default"
#define SQL_DBNAME		"donators"

#define DONATOR_VERSION "0.8"

#define CHAT_TRIGGER 	"!donators"
#define DONATOR_FILE	"configs/donators.ini"

new Handle:g_hForward_OnDonatorConnect = INVALID_HANDLE;
new Handle:g_hForward_OnPostDonatorCheck = INVALID_HANDLE;
new Handle:g_hForward_OnDonatorsChanged = INVALID_HANDLE;

new Handle:g_hDonatorTrie = INVALID_HANDLE;
new Handle:g_hDonatorTagTrie = INVALID_HANDLE;
new Handle:g_hMenuItems = INVALID_HANDLE;

new bool:g_bIsDonator[MAXPLAYERS + 1];
new g_iMenuId, g_iMenuCount;

#if defined USE_SQL
new Handle:g_hDataBase = INVALID_HANDLE;
enum SQLCOLS { steamid, level, tag }; //add cols to expand the sql storage
new const String:db_cols[SQLCOLS][] = { "steamid", "level", "tag" };
#else
new Handle:g_hCookieLevel = INVALID_HANDLE;
new Handle:g_hCookieTag = INVALID_HANDLE;
#endif

public Plugin:myinfo = 
{
	name = "Donator Interface",
	author = "Nut",
	description = "A core to handle donator related plugins",
	version = DONATOR_VERSION,
	url = "http://www.lolsup.com/tf2"
}

public OnPluginStart()
{
	CreateConVar("basicdonator_version", DONATOR_VERSION, "Basic Donators Version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	RegAdminCmd("sm_reloaddonators", cmd_ReloadDonators, ADMFLAG_BAN, "Reloads the donator database");
	
	g_hDonatorTrie = CreateTrie();
	g_hDonatorTagTrie = CreateTrie();
	
	#if defined USE_SQL
	SQL_OpenConnection();
	#else
	g_hCookieLevel = RegClientCookie("donator.core.level", "Donator access level", CookieAccess_Private);
	g_hCookieTag = RegClientCookie("donator.core.tag", "Donator tag", CookieAccess_Public);
	LoadDonatorFile();
	#endif
	
	g_hForward_OnDonatorConnect = CreateGlobalForward("OnDonatorConnect", ET_Event, Param_Cell);
	g_hForward_OnPostDonatorCheck = CreateGlobalForward("OnPostDonatorCheck", ET_Event, Param_Cell);
	g_hForward_OnDonatorsChanged = CreateGlobalForward("OnDonatorsChanged", ET_Event);

	g_hMenuItems = CreateArray();

	AddCommandListener(SayCallback, "say");
	AddCommandListener(SayCallback, "say_team");
}

#if defined USE_SQL
public OnPluginEnd()
{
	if (g_hDataBase != INVALID_HANDLE)
		CloseHandle(g_hDataBase);
}
#endif

public OnClientPostAdminCheck(iClient)
{
	if(IsFakeClient(iClient)) return;
	new String:szSteamId[64];
	GetClientAuthString(iClient, szSteamId, sizeof(szSteamId));
	
	g_bIsDonator[iClient] = false;

	decl iLevel;
	if (GetTrieValue(g_hDonatorTrie, szSteamId, iLevel))
	{
		g_bIsDonator[iClient] = true;
		Forward_OnDonatorConnect(iClient);
	}
	
	#if defined USE_SQL
	if (!g_bIsDonator[iClient] && g_hDataBase != INVALID_HANDLE)
	{
		new String:szBuffer[256];
		FormatEx(szBuffer, sizeof(szBuffer), "SELECT %s, %s, %s FROM `%s` WHERE `STEAMID` LIKE '%s'", db_cols[steamid], db_cols[level], db_cols[tag], SQL_DBNAME, szSteamId);
		SQL_TQuery(g_hDataBase, T_CheckConnectingUsr, szBuffer, GetClientUserId(iClient));
	}
	#else
	if (g_bIsDonator[iClient] && AreClientCookiesCached(iClient))
	{
		new String:szLevelBuffer[2], String:szBuffer[256];
		GetClientCookie(iClient, g_hCookieLevel, szLevelBuffer, sizeof(szLevelBuffer));
		GetClientCookie(iClient, g_hCookieTag, szBuffer, sizeof(szBuffer));

		if (strlen(szBuffer) > 1)
		{
			SetTrieValue(g_hDonatorTrie, szSteamId, StringToInt(szLevelBuffer));
			SetTrieString(g_hDonatorTagTrie, szSteamId, szBuffer, true);
		}
	}
	#endif
	
	Forward_OnPostDonatorCheck(iClient);
}

public Action:SayCallback(iClient, const String:command[], argc)
{
	if (!iClient) return Plugin_Continue;
	if (!g_bIsDonator[iClient]) return Plugin_Continue;
	
	decl String:szArg[255];
	GetCmdArgString(szArg, sizeof(szArg));

	StripQuotes(szArg);
	TrimString(szArg);

	if (StrEqual(szArg, CHAT_TRIGGER, false))
	{
		ShowDonatorMenu(iClient);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action:ShowDonatorMenu(iClient)
{
	new Handle:hMenu = CreateMenu(DonatorMenuSelected);
	SetMenuTitle(hMenu,"Donator Menu");

	SortADTArrayCustom(g_hMenuItems, ArrayADTCustomCallback);

	decl Handle:hItem, String:szBuffer[64], String:szItem[4];
	for(new i = 0; i < GetArraySize(g_hMenuItems); i++)
	{
		FormatEx(szItem, sizeof(szItem), "%i", i);
		hItem = GetArrayCell(g_hMenuItems, i);
		GetArrayString(hItem, 1, szBuffer, sizeof(szBuffer));
		AddMenuItem(hMenu, szItem, szBuffer, ITEMDRAW_DEFAULT);
	}
	DisplayMenu(hMenu, iClient, 20);
}

public ArrayADTCustomCallback(index1, index2, Handle:array, Handle:hndl)
{
	new Handle:hMinItem = GetArrayCell(g_hMenuItems, index1);
	new Handle:hMinItem1 = GetArrayCell(g_hMenuItems, index2);

	decl String:buffer1[64], String:buffer2[64];
	GetArrayString(hMinItem, 1, buffer1, sizeof(buffer1));
	GetArrayString(hMinItem1, 1, buffer2, sizeof(buffer2));

	return strcmp(buffer1, buffer2, false);
}

public DonatorMenuSelected(Handle:menu, MenuAction:action, param1, param2)
{
	decl String:szTemp[6], iSelected;
	GetMenuItem(menu, param2, szTemp, sizeof(szTemp));
	iSelected = StringToInt(szTemp);

	switch (action)
	{
		case MenuAction_Select:
		{
			new Handle:hItem = GetArrayCell(g_hMenuItems, iSelected);
			new Handle:hFwd = GetArrayCell(hItem, 3);
			new bool:result;
			Call_StartForward(hFwd);
			Call_PushCell(param1);
			Call_Finish(result);
		}
		case MenuAction_End: CloseHandle(menu);
	}
}

public Action:cmd_ReloadDonators(client, args)
{	
	new String:szAuthId[64], String:szBuffer[255];

	#if defined USE_SQL
	for(new i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i)) continue;
		if (IsFakeClient(i)) continue;

		g_bIsDonator[i] = false;
		GetClientAuthString(i, szAuthId, sizeof(szAuthId));
		
		if (g_hDataBase != INVALID_HANDLE)
		{
			FormatEx(szBuffer, sizeof(szBuffer), "SELECT %s, %s, %s FROM `%s` WHERE `STEAMID` LIKE '%s'", db_cols[steamid], db_cols[level], db_cols[tag], SQL_DBNAME, szAuthId);
			SQL_TQuery(g_hDataBase, T_CheckConnectingUsr, szBuffer, GetClientUserId(i));
		}
	}
	#else
	LoadDonatorFile();
	#endif
	
	
	for(new i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i)) continue;
		if (IsFakeClient(i)) continue;
		g_bIsDonator[i] = false;
		
		GetClientAuthString(i, szAuthId, sizeof(szAuthId));

		#if !defined USE_SQL
		decl iLevel;
		if (GetTrieValue(g_hDonatorTrie, szAuthId, iLevel))
		{
			GetClientCookie(i, g_hCookieTag, szBuffer, sizeof(szBuffer));
			SetTrieString(g_hDonatorTagTrie, szAuthId, szBuffer, true);
			g_bIsDonator[i] = true;
		}
		#endif
	}
	
	ReplyToCommand(client, "[SM] Donator database reloaded.");
	Forward_OnDonatorsChanged();
	return Plugin_Handled;
}

#if !defined USE_SQL
public LoadDonatorFile()
{
	decl String:szBuffer[255];

	BuildPath(Path_SM, szBuffer, sizeof(szBuffer), DONATOR_FILE);
	new Handle:file = OpenFile(szBuffer, "r");
	if (file != INVALID_HANDLE)
	{
		szBuffer = "";
		ClearTrie(g_hDonatorTagTrie);
		ClearTrie(g_hDonatorTrie);
		while (!IsEndOfFile(file) && ReadFileLine(file, szBuffer, sizeof(szBuffer)))
			if (szBuffer[0] != ';' && strlen(szBuffer) > 1)
			{
				decl String:szTemp[2][64];
				TrimString(szBuffer);
				ExplodeString(szBuffer, ";", szTemp, 2, sizeof(szTemp[]));
				SetTrieValue(g_hDonatorTrie, szTemp[0], StringToInt(szTemp[1]));
			}
		CloseHandle(file);
	}
	else
		SetFailState("Unable to load donator file (%s)", szBuffer);
}
#endif

//--------------------------------------SQL---------------------------------------------

#if defined USE_SQL
public SQL_OpenConnection()
{
	if (SQL_CheckConfig(SQL_CONFIG))
		SQL_TConnect(T_InitDatabase, SQL_CONFIG);
	else
		SetFailState("Unabled to load cfg file (%s)", SQL_CONFIG);
}

public T_InitDatabase(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl != INVALID_HANDLE)
		g_hDataBase = hndl;
	else  
		LogError("DATABASE FAILURE: %s", error);
}


public T_FindDonatorBySteamId(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
		LogError("Query failed! %s", error);
	else 
	{
		new String:szSteamId[64], String:szTag[265];

		if (SQL_GetRowCount(hndl))
			while (SQL_FetchRow(hndl))
			{
				SQL_FetchString(hndl, 0, szSteamId, sizeof(szSteamId));
				new iLevel = SQL_FetchInt(hndl, 1);
				SQL_FetchString(hndl, 2, szTag, sizeof(szTag));
				SetTrieValue(g_hDonatorTrie, szSteamId, iLevel);
				SetTrieString(g_hDonatorTagTrie, szSteamId, szTag);
			}
	}
}


public T_CheckConnectingUsr(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	decl iClient, String:szSteamId[64];
	if ((iClient = GetClientOfUserId(data)) == 0) return;	//Make sure the client didn't disconnect
	GetClientAuthString(iClient, szSteamId, sizeof(szSteamId));
	
	if (hndl == INVALID_HANDLE)
		LogError("Query failed! %s", error);
	else 
	{
		new String:szTag[265];

		if (SQL_GetRowCount(hndl))
		{
			while (SQL_FetchRow(hndl))
			{
				new iLevel = SQL_FetchInt(hndl, 1);
				SQL_FetchString(hndl, 2, szTag, sizeof(szTag));
				SetTrieValue(g_hDonatorTrie, szSteamId, iLevel);
				SetTrieString(g_hDonatorTagTrie, szSteamId, szTag);

				if (IsClientInGame(iClient))
					g_bIsDonator[iClient] = true;
			}
		}
	}
}

public T_ReloadDonators(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl != INVALID_HANDLE)
	{
		if (SQL_GetRowCount(hndl))
		{
			ClearTrie(g_hDonatorTagTrie);
			ClearTrie(g_hDonatorTrie);
			decl String:szSteamId[64], String:szTag[256], iLevel;
			while (SQL_FetchRow(hndl))
			{
				SQL_FetchString(hndl, 0, szSteamId, sizeof(szSteamId));
				if (strlen(szSteamId) < 1) continue;

				iLevel = SQL_FetchInt(hndl, 1);
				SQL_FetchString(hndl, 2, szTag, sizeof(szTag));
				SetTrieValue(g_hDonatorTrie, szSteamId, iLevel);
				SetTrieString(g_hDonatorTagTrie, szSteamId, szTag);
			}
		}
	}
	else
		LogError("Query failed! %s", error);
}

public SQLErrorCheckCallback(Handle:owner, Handle:hndl, const String:error[], any:data)
	if (strlen(error) > 1)
		LogMessage("SQL Error: %s", error);
#endif

//-----------------------------------------------------------------------------------------

/*
* Natives
*/
public Native_GetDonatorLevel(Handle:plugin, params)
{
	decl String:szSteamId[64], iLevel;
	GetClientAuthString(GetNativeCell(1), szSteamId, sizeof(szSteamId));
	
	if (GetTrieValue(g_hDonatorTrie, szSteamId, iLevel))
		return iLevel;
	else
		return -1;
}

public Native_SetDonatorLevel(Handle:plugin, params)
{
	/*
	decl String:szSteamId[64], iLevel;
	GetClientAuthString(GetNativeCell(1), szSteamId, sizeof(szSteamId));

	if (GetTrieValue(g_hDonatorTrie, szSteamId, iLevel))
	{
		iLevel = GetNativeCell(2);
		SetTrieValue(g_hDonatorTrie, szSteamId, iLevel);

		#if defined USE_SQL
		SQL_EscapeString(g_hDataBase, szSteamId, szSteamId, sizeof(szSteamId));
		decl String:szQuery[512];
		FormatEx(szQuery, sizeof(szQuery), "UPDATE `%s` SET %s = %i WHERE `steamid` LIKE '%s'", SQL_DBNAME, db_cols[level], iLevel, szSteamId);
		SQL_TQuery(g_hDataBase, SQLErrorCheckCallback, szQuery);
		#else
		decl String:szLevel[5];
		Format(szLevel, sizeof(szLevel), "%i", iLevel);
		SetClientCookie(GetNativeCell(1), g_CookieLevel, szLevel);
		#endif
		return true;
	}
	else
		return -1;*/
		
	ThrowNativeError(SP_ERROR_NATIVE, "Not implimented.");
}

public Native_IsClientDonator(Handle:plugin, params)
{
	decl String:szSteamId[64], iLevel;
	GetClientAuthString(GetNativeCell(1), szSteamId, sizeof(szSteamId));
	if (GetTrieValue(g_hDonatorTrie, szSteamId, iLevel))
		return true;
	return false;
}

public Native_FindDonatorBySteamId(Handle:plugin, params)
{
	decl String:szSteamId[64], iLevel;
	GetNativeString(1, szSteamId, sizeof(szSteamId));

	#if defined USE_SQL
	decl String:szBuffer[256];
	
	if (g_hDataBase != INVALID_HANDLE)
	{
		FormatEx(szBuffer, sizeof(szBuffer), "SELECT %s, %s, %s FROM `%s` WHERE `STEAMID` LIKE '%s'", db_cols[steamid], db_cols[level], db_cols[tag], SQL_DBNAME, szSteamId);
		SQL_TQuery(g_hDataBase, T_FindDonatorBySteamId, szBuffer);
	}
	#endif
	
	if (GetTrieValue(g_hDonatorTrie, szSteamId, iLevel))
		return true;

	return false;
}

public Native_GetDonatorMessage(Handle:plugin, params)
{
	decl String:szBuffer[256], String:szSteamId[64];
	GetClientAuthString(GetNativeCell(1), szSteamId, sizeof(szSteamId));

	if (GetTrieString(g_hDonatorTagTrie, szSteamId, szBuffer, 256))
	{
		SetNativeString(2, szBuffer, 256, true);
		return true;
	}
	return -1;
}

public Native_SetDonatorMessage(Handle:plugin, params)
{
	decl String:szOldTag[256], String:szSteamId[64], String:szNewTag[256];
	GetClientAuthString(GetNativeCell(1), szSteamId, sizeof(szSteamId));
	
	if (GetTrieString(g_hDonatorTagTrie, szSteamId, szOldTag, 256))
	{
		GetNativeString(2, szNewTag, sizeof(szNewTag));
		SetTrieString(g_hDonatorTagTrie, szSteamId, szNewTag);
		
		#if defined USE_SQL
		decl String:szQuery[512];
		SQL_EscapeString(g_hDataBase, szNewTag, szNewTag, sizeof(szNewTag));
		SQL_EscapeString(g_hDataBase, szSteamId, szSteamId, sizeof(szSteamId));
		if (g_hDataBase != INVALID_HANDLE)
		{
			FormatEx(szQuery, sizeof(szQuery), "UPDATE `%s` SET %s = '%s' WHERE `steamid` LIKE '%s'", SQL_DBNAME, db_cols[tag], szNewTag, szSteamId);
			SQL_TQuery(g_hDataBase, SQLErrorCheckCallback, szQuery);
		}
		#else
		SetClientCookie(GetNativeCell(1), g_hCookieTag, szNewTag);
		#endif
		
		return true;
	}
	return -1;
}

public Native_RegisterMenuItem(Handle:hPlugin, iNumParams)
{
	decl String:szCallerName[PLATFORM_MAX_PATH], String:szBuffer[256], String:szMenuTitle[256];
	GetPluginFilename(hPlugin, szCallerName, sizeof(szCallerName));
	
	new Handle:hFwd = CreateForward(ET_Single, Param_Cell, Param_CellByRef);	
	if (!AddToForward(hFwd, hPlugin, GetNativeCell(2)))
		ThrowError("Failed to add forward from %s", szCallerName);

	GetNativeString(1, szMenuTitle, 255);
	
	new Handle:hTempItem;
	for (new i = 0; i < g_iMenuCount; i++)	//make sure we aren't double registering
	{
		hTempItem = GetArrayCell(g_hMenuItems, i);
		GetArrayString(hTempItem, 1, szBuffer, sizeof(szBuffer));
		if (StrEqual(szMenuTitle, szBuffer))
		{
			RemoveFromArray(g_hMenuItems, i);
			g_iMenuCount--;
		}
	}
	
	new Handle:hItem = CreateArray(15);
	new id = g_iMenuId++;
	g_iMenuCount++;
	PushArrayString(hItem, szCallerName);
	PushArrayString(hItem, szMenuTitle);
	PushArrayCell(hItem, id);
	PushArrayCell(hItem, hFwd);
	PushArrayCell(g_hMenuItems, hItem);

	return id;
}

public Native_UnregisterMenuItem(Handle:hPlugin, iNumParams)
{
	new Handle:hTempItem;
	for (new i = 0; i < g_iMenuCount; i++)
	{
		hTempItem = GetArrayCell(g_hMenuItems, i);
		new id = GetArrayCell(hTempItem, 2);
		if (id == GetNativeCell(1))
		{
			RemoveFromArray(g_hMenuItems, i);
			g_iMenuCount--;
			return true;
		}
	}
	return false;
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	RegPluginLibrary("donator.core");
	
		/*
	* 	strcopy(error, err_max, "This game is not yet supported"); 
	* 	return APLRes_Failure;
	*/
	
	CreateNative("IsPlayerDonator", Native_IsClientDonator);
	CreateNative("FindDonatorBySteamId", Native_FindDonatorBySteamId);
	CreateNative("GetDonatorLevel", Native_GetDonatorLevel);
	CreateNative("SetDonatorLevel", Native_SetDonatorLevel);
	CreateNative("GetDonatorMessage", Native_GetDonatorMessage);
	CreateNative("SetDonatorMessage", Native_SetDonatorMessage);
	CreateNative("Donator_RegisterMenuItem", Native_RegisterMenuItem);
	CreateNative("Donator_UnregisterMenuItem", Native_UnregisterMenuItem);
	return APLRes_Success;
}

//-------------------FORWARDS--------------------------
/*
* Forwards for donators connecting
*/
public Forward_OnDonatorConnect(iClient)
{
	new bool:result;
	Call_StartForward(g_hForward_OnDonatorConnect);
	Call_PushCell(iClient);
	Call_Finish(_:result);
	return result;
}

/*
*  Forwards for everyone - use to check for admin status/ cookies should be cached now
*/
public Forward_OnPostDonatorCheck(iClient)
{
	new bool:result;
	Call_StartForward(g_hForward_OnPostDonatorCheck);
	Call_PushCell(iClient);
	Call_Finish(_:result);
	return result;
}

/*
*  Forwards when the donators have been reloaded
*/
public Forward_OnDonatorsChanged()
{
	new bool:result;
	Call_StartForward(g_hForward_OnDonatorsChanged);
	Call_Finish(_:result);
	return result;
}