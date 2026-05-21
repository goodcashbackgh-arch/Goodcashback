import { redirect } from "next/navigation";

export default function NewCustomerOrderPage() {
  redirect("/importer/orders/new");
}
