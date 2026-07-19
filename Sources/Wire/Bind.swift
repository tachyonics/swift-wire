/// Name the keyed binding an `@Inject init` parameter should resolve to.
///
/// `@Inject(Key)` keys a *property* (`@Inject(Database.primary) var db: Database`), but `@Inject` is a
/// peer macro and Swift does not allow a macro attribute on a function parameter. When the dependency has
/// to arrive through a custom initialiser — the usual case for a `@Singleton` that does async setup work in
/// `init` — the parameter carries `@Bind(Key)` instead. It is a property wrapper (which *can* attach to a
/// parameter), transparent at runtime: the initialiser sees the plain value, and the generated bootstrap
/// passes it positionally, exactly as for an unkeyed parameter. Only the build plugin reads the key.
///
///     enum CouchDB {
///         static let httpClient = BindingKey<HTTPClient>()
///     }
///
///     @Singleton(as: TodoRepository.self)
///     struct CouchDBTodoRepository: TodoRepository {
///         @Inject init(@Bind(CouchDB.httpClient) client: HTTPClient) async throws { … }
///     }
///
/// An unkeyed parameter still resolves by type; `@Bind` is only needed to pick among several bindings of
/// the same type. `Value` unifies with the parameter's type, so `@Bind(Database.primary) cache: Cache`
/// fails to compile.
@propertyWrapper
public struct Bind<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value, _ key: BindingKey<Value>) {
        self.wrappedValue = wrappedValue
    }
}
