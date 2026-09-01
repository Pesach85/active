using System.Runtime.InteropServices;
using System.Security.Principal;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Windows;

public static class WindowsOperatorAuth
{
    public static OperatorIdentity GetCurrentIdentity()
    {
        var id = WindowsIdentity.GetCurrent();
        var name = id.Name ?? Environment.UserName;
        var user = Environment.UserName;
        var domain = Environment.UserDomainName;
        if (name.Contains('\\'))
        {
            var parts = name.Split('\\', 2);
            domain = parts[0];
            user = parts[1];
        }

        var isAdmin = false;
        try
        {
            var principal = new WindowsPrincipal(id);
            isAdmin = principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { }

        return new OperatorIdentity(name, user, domain, isAdmin);
    }

    public static bool ValidatePassword(string password, string? userName = null, string? domain = null)
    {
        if (string.IsNullOrWhiteSpace(password))
            return false;

        var identity = GetCurrentIdentity();
        userName ??= identity.UserName;
        domain ??= identity.Domain;

        try
        {
            if (PrincipalContextValidate(userName, password, domain))
                return true;
        }
        catch { }

        var domainsToTry = new[] { domain, Environment.MachineName, "." }
            .Where(d => !string.IsNullOrWhiteSpace(d))
            .Distinct(StringComparer.OrdinalIgnoreCase);

        foreach (var d in domainsToTry)
        {
            if (LogonUserValidate(d, userName, password))
                return true;
        }

        return false;
    }

    public static OperatorAuthResult AssertPassword(string password, bool skipAuth)
    {
        var identity = GetCurrentIdentity();
        if (skipAuth)
            return new OperatorAuthResult(true, true, identity);

        if (!ValidatePassword(password))
            throw new InvalidOperationException("Windows password verification failed - action blocked.");

        return new OperatorAuthResult(true, false, identity);
    }

    public static OperatorAuthResult AssertAuth(string? password, string? sessionToken, bool skipAuth)
    {
        var identity = GetCurrentIdentity();
        if (skipAuth)
            return new OperatorAuthResult(true, true, identity);

        if (OperatorHitlSessionStore.TryValidate(sessionToken, out _))
            return new OperatorAuthResult(true, false, identity);

        if (!string.IsNullOrWhiteSpace(password))
            return AssertPassword(password, skipAuth: false);

        throw new InvalidOperationException("HITL session expired or missing. Unlock from HITL Paths panel first.");
    }

    public static string StartSession(string password, bool skipAuth, TimeSpan? ttl = null)
    {
        if (!skipAuth)
        {
            if (!ValidatePassword(password))
                throw new InvalidOperationException("Windows password verification failed - session blocked.");
        }

        var identity = GetCurrentIdentity();
        return OperatorHitlSessionStore.Start(identity.FullName, ttl ?? TimeSpan.FromMinutes(45), riskAcknowledged: true);
    }

    private static bool PrincipalContextValidate(string userName, string password, string domain)
    {
        // System.DirectoryServices.AccountManagement when available
        var asm = AppDomain.CurrentDomain.GetAssemblies()
            .FirstOrDefault(a => a.GetName().Name == "System.DirectoryServices.AccountManagement");
        if (asm is null)
            return false;

        var ctxType = asm.GetType("System.DirectoryServices.AccountManagement.ContextType");
        var pcType = asm.GetType("System.DirectoryServices.AccountManagement.PrincipalContext");
        if (ctxType is null || pcType is null)
            return false;

        var machine = Enum.Parse(ctxType, "Machine");
        var domainEnum = Enum.Parse(ctxType, "Domain");

        foreach (var ctxInfo in new[] { (machine, (string?)null), (domainEnum, domain) })
        {
            try
            {
                var ctx = ctxInfo.Item2 is null
                    ? Activator.CreateInstance(pcType, ctxInfo.Item1)!
                    : Activator.CreateInstance(pcType, ctxInfo.Item1, ctxInfo.Item2)!;

                var validate = pcType.GetMethod("ValidateCredentials", [typeof(string), typeof(string)]);
                if (validate?.Invoke(ctx, [userName, password]) is true)
                    return true;
            }
            catch { }
        }

        return false;
    }

    private static bool LogonUserValidate(string domain, string userName, string password)
    {
        if (!LogonUser(userName, string.IsNullOrWhiteSpace(domain) ? "." : domain, password,
                Logon32LogonInteractive, Logon32ProviderDefault, out var token))
            return false;

        try
        {
            return token != IntPtr.Zero;
        }
        finally
        {
            if (token != IntPtr.Zero)
                CloseHandle(token);
        }
    }

    private const int Logon32LogonInteractive = 2;
    private const int Logon32ProviderDefault = 0;

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(
        string lpszUsername, string lpszDomain, string lpszPassword,
        int dwLogonType, int dwLogonProvider, out IntPtr phToken);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
